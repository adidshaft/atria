# 23 — Codex handoff: graphs, readability, and a possible 4th tab

This builds **on top of** the WHOOP-language + accuracy foundation that just landed
(commits `0b444cfc` → `9d8db8b0`). Read "Foundation" first so you reuse the
primitives instead of re-deriving them, then Parts A–C. The hard/soft requirements
at the end are non-negotiable vs nice-to-have — keep them in view on every change.

Goal of this handoff: make Atria **more user-friendly** — readable graphs, less
number-soup, clearer at-a-glance meaning — without regressing the accuracy or the
native Liquid Glass feel.

---

## Foundation — what just landed (build on these, do NOT redo)

| Commit | What it gave you (reuse it) |
|---|---|
| `0b444cfc` | **Electric readiness palette** in `Metrics.swift`: `electricGreen / electricYellow / electricRed / electricStrain`, all light/dark-adaptive via `Metrics.adaptive(dark:light:)`. `recoveryColor` routes through them. |
| `076d58d9` | **Live-number transitions**: `.contentTransition(.numericText())` + `.animation(.snappy(0.3), value:)` on HR heroes, glance cards, `AtriaMetricTile`. |
| `642dd2b0` | **Light-mode card elevation** (soft shadow on `AtriaCardBackground`/`AtriaRaisedCardBackground`, light only) + RHR identity is `.pink` not alarm `.red`. |
| `31d7268d` | **Sleep-window HRV baseline**: `PersonalBaseline.BaselineSample.overnight` flag, `lnRMSSDStats(now:)` prefers overnight samples (≥7), `SavedSession.isOvernightHRVWindow()`. Self-tested via LabelChecks. |
| `ea2a5973` | **Recovery freezes to the morning reading** (WHOOP-like): `ble.recoveryHRVSnapshot` (live snapshot only inside 4–11am), `latestLocalRMSSD` prefers the latest overnight session. |
| `9d8db8b0` | **Strain is one electric blue** (`Metrics.strainColor` → `electricStrain`); effort no longer reads as bad recovery. |

**Reusable primitives — prefer these over inventing new ones:**
- Metric colors → `Metrics.electricGreen/Yellow/Red/electricStrain`. Never reintroduce soft system `.green/.yellow/.red` for recovery, or a warm ramp for strain.
- Any new metric color that must be legible in both modes → `Metrics.adaptive(dark:light:)`.
- Any live/changing number → `.monospacedDigit().contentTransition(.numericText()).animation(.snappy(0.3), value: <theValue>)`.
- HRV/recovery inputs are already sleep-windowed — **do not** feed daytime HRV back into recovery (see Hard Requirements).

---

## Part A — Graphs & readability (the main ask)

### A1. Trend graphs (Swift Charts) — **inside tap-through detail views, NOT a tab**
Charts live **inside each metric's detail view** (tap a glance card → detail with its
own chart), the WHOOP pattern — see Part B for why this beats a graphs tab.
- One chart per metric: **Recovery**, **HRV (lnRMSSD)**, **RHR**, **Sleep duration/performance**, **Strain/day-load**.
- Ranges: **week / month / quarter** segmented (native `Picker(.segmented)`).
- Color each point/band by zone using the **electric palette** (recovery green/amber/red; strain electric blue).
- Show the **personal baseline band** (mean ± SD from `PersonalBaseline.lnRMSSDStats`) behind the HRV/RHR series so a point reads as "above/below my normal" — the WHOOP-style "is this good for *me*" framing.
- Also drop a 7-point **sparkline** on the glance tile itself (reuse `Sparkline`, downsampled once) so the trend is visible before the tap.
- **Data source / wiring:** a daily recovery/HRV/RHR value must be **persisted to history** so it can be charted. Today recovery is computed live and not stored per-day. Add a small daily-rollup (one value/day, written once when the morning reading settles) to the `SessionStore`; do **not** recompute the series on every render (Hard Req: perf).

### A2. Recovery contributors (the "why")
WHOOP's most-loved recovery detail is the **contributor breakdown**. `recoveryV2`
already combines lnRMSSD-z + RHR-z + sleep + RSA-respiratory — **expose the signed
per-term z-components** out of `AtriaAnalytics.Recovery.estimate` (currently they
collapse into one score) and render a small **contributor list / waterfall**:
"HRV +1.2σ ↑, RHR −0.4σ ↓, Sleep ok, Respiration ok → 64%". This is the single
highest-value readability win — it turns a number into an explanation.

### A3. Banded strain dial
Turn the plain strain ring into WHOOP's labeled-band gauge: faint arc zones
0–9 / 10–13 / 14–17 / 18–21 (Light/Moderate/High/All-Out), the active band labelled
under the number, and a translucent **target arc + optimal notch** from the
recovery-scaled target (`heroStore.state.guidance.target` already exists). Keep the
fill electric-blue; bands are faint tick marks, not warm hues.

### A4. Sleep visual
An honest **hypnogram** (light/deep/REM/awake over the night) — but **label it as an
HR/IMU-derived estimate, not EEG** (see Hard Req on honesty). Plus sleep
performance % (got vs need) and a consistency bar.

### A5. Readability pass (cheap, broad)
- Fewer numbers per glance tile; lead with the value + a one-word state, push detail to a tap.
- Sparklines on the glance HRV/RHR/recovery tiles (last 7 pts) — reuse the existing `Sparkline` view, downsampled once.
- Every metric gets a "what does this mean / what do I do" **(i) sheet** (Part-D pattern) — coaching, not just definitions.
- Consistent units and consistent decimal places; right-align monospaced digits.

---

## Part B — 4th bottom-bar tab: **DECIDED — no. Keep 3 tabs.**

Current tabs: **Overview · Vitals · Data** (`HomeTab.overview/.vitals/.collection`,
`TabView` in `AtriaHomeView.swift:161`, native floating glass with
`.tabBarMinimizeBehavior(.onScrollDown)`). **This stays. Do not add a 4th tab.**

**Why no graphs tab:**
- **WHOOP has no graphs tab.** Trends live *inside* each pillar's detail screen
  (open Recovery → its trend; open Sleep → its trend). Atria copies that: tap a
  glance card → detail view *with its own chart* (Part A1). Contextual + discoverable
  by curiosity, and it's the authentic pattern.
- Atria's IA is **already overlapping** — there's a "Data" *tab*, a "Data"
  *sub-segment*, and a "Trends" *sub-segment*. Adding a 4th tab on top of that is
  bloat. (Bonus task: untangle that overlap — the Overview Today/Trends/Data
  sub-segment vs the tabs. Pick one mechanism.)
- A graphs tab would be a secondary "museum," not a daily destination; a near-empty
  tab is worse than none.
- `Data` (backup/export/sensor signals) is power-user but it's part of Atria's
  identity (local, no-sub, you own your data) — leave it as a tab.

**What replaces the 4th-tab ambition → the coaching hero (Part C1).** The genuinely
missing high-value WHOOP feature is *actionable coaching*, and it belongs as the
**first thing on Overview**, not behind a tab. See C1 — promote it to the top of this
handoff's priority order.

(If, much later, coaching + journal + a weekly assessment grow into a real surface, a
single **"Coach"** tab could be justified — but only then, and never a graphs tab.)

---

## Part C — Higher-leverage user-facing features (from the research, ranked)

### C1. **"Today's Plan" coaching hero — TOP PRIORITY (this is what replaces the 4th tab)**
The #1 differentiator and the single most user-friendly thing Atria can add. A hero
card at the **top of Overview** (above "Today at a glance") that answers *"what do I
do today?"* in one read:
> **Recovery 31% — take it easy.** Target strain **8–10**. Prioritize sleep tonight (you're 1h12m in debt).

- Rules-based, **no cloud/AI** — drive it from what already exists: `recoveryV2`
  band, the recovery-scaled strain target (`heroStore.state.guidance.target`),
  ACWR/monotony (ReadinessEngine), sleep debt.
- Three tiers max: green ("you're primed — go after it, target strain 14–18"),
  amber ("moderate — hold steady"), red ("take it easy / rest").
- Honest: while baselines are "Building", say so ("learning your baseline — N more
  nights") instead of inventing a verdict.
- It's a card, not a tab — uses the existing card chrome + electric palette + (i)
  sheet for the "why".

### C2. The rest (ranked)
1. ~~Actionable coaching~~ → done as C1 above.
2. **Journal / behavior → recovery correlation** — log alcohol/caffeine/stress/late-meal, show mean-delta vs no-behavior with sample size. (`behaviorInsights` exists; deepen it. Be honest: it's a local mean-delta + n, **not** a cloud-ML "isolated contribution".)
3. **Sleep coach** — sleep need (baseline + strain + debt), debt, consistency.
4. **Recovery-scaled strain target / "today's plan"** — already partly specced; surface it on Overview and mid-workout (target arc, push/hold/ease).
5. **Trends depth** — week/month/year heatmap + period comparisons (Part A).

---

## Hard requirements (MUST — these are load-bearing; a PR that breaks one is wrong)

- **Local only.** No cloud, no network, no account, no HTTPS, no analytics SDK. Everything on-device.
- **No `sparkles` SF Symbol**, anywhere.
- **Honesty / fail-closed.** Never fabricate a metric. Gate on ≥14 personal-baseline nights (`PersonalBaseline.trustedMinimumSamples`); show "Building" until ready. Mark estimates as estimates.
- **Keep HRV sleep-windowed.** Recovery's HRV input is morning-frozen (`ble.recoveryHRVSnapshot`) and the baseline is overnight-preferred. **Do not** reintroduce live daytime HRV into recovery, and don't undo the morning-freeze. Recovery should not drift during the day.
- **Don't bypass RR cleaning.** RMSSD/lnRMSSD must be computed on the ectopic-cleaned series (`HRV.swift` 300–2000ms + 20% neighbor-median rejection). Don't compute HRV on raw RR.
- **Native Liquid Glass only, done right.** Use `.buttonStyle(.glass)` / `.glassProminent` / `.pickerStyle(.segmented)` and `.glassEffect`. **Never** put an opaque/near-opaque fill *under* `.glassEffect` (that was the bug that made buttons flat white discs). One `.glassProminent` primary action per surface.
- **Light AND dark both legible.** Verify every color/graph in both. Use `Metrics.adaptive` for metric colors. Pure electric hues are dark-tuned — deepen for light.
- **Perf: nothing heavy on the render path.** No `.sorted/.reduce/.map/.filter`/rollups/`detectedActivity()`/daily-rollups inside a `var body` or a computed `some View`. Cache in the store; the render path is currently fully cached — **keep it that way**. Charts must downsample **once** (at init), not per-render.
- **Keep `test_handoff_static_checks.py` green**, and add guards for any new invariant you introduce (follow the existing LabelCheck / token-guard pattern; the accuracy work added self-tests — do the same).
- **Verify on Release, on device.** Debug renders glass 30–50× slower — never judge perf or "lag" from a Debug/Simulator build.

## Soft requirements (SHOULD — strong defaults, deviate only with a reason)

- Match WHOOP's **at-a-glance clarity**: one primary number per tile, color = meaning, detail on tap.
- Any new live number → `.contentTransition(.numericText())` (consistency with the heroes).
- Reuse the existing **drag-drop card customization** + **editable target zones**; new metrics should slot into both.
- **Small, single-purpose commits**, each independently device-verified. Don't bundle a refactor with a feature.
- Prefer extending shared components (`AtriaGlanceMetricCard`, `AtriaMetricTile`, `AtriaMetricRing`, the card backgrounds) over new bespoke views — it keeps the language consistent and the perf characteristics known.
- Charts: Swift Charts, zone-colored, baseline band behind, accessible (VoiceOver summary of the trend).

## Honest "we can't match WHOOP here" list (keep these gated, don't over-promise)

- **True sleep staging** (deep/REM): HR+IMU estimate, not EEG/PSG — label as estimate; ~60–80% is the industry ceiling.
- **Absolute SpO₂ %** and **absolute skin temperature**: research-gated, relative-only, sleep-only (this *matches* WHOOP's own conservative methodology — don't show a fake absolute number).
- **Strap haptics** (silent alarm, on-wrist buzz): Atria is a read-only BLE central; phone-side haptics only.
- **Activity-type auto-classification** (run vs lift vs cycle): no GPS/IMU ML — detect *that* an activity happened; type is a manual label.
- **Weather / environmental context** and **cloud-ML journal "isolated contribution"**: blocked by the no-network constraint — physiology-only, honest mean-delta only.

## Open risks / things to watch

- **RR-stream reliability at rest is the #1 data risk** (proprietary realtime RR is flaky on some units; HRV → recovery → sleep all depend on it). If a chart looks empty/sparse, suspect RR flow, not the chart.
- **Recovery contributors (A2)** now depend on the exposed per-term z outputs from `recoveryV2`; keep the formula identical and treat the contributor list as explanatory UI, not a new scoring path.
- **Daily history persistence (A1)** now exists, but the semantics still matter: decide whether the saved per-day recovery/HRV/RHR snapshot should be written only when the morning reading settles, or whether the current republished-rollup approach is acceptable.

## Implementation status — June 30, 2026

Implemented in the app:
- `Today's Plan` coaching hero now appears at the top of Overview, including the saved/disconnected returning-user path.
- The Today tab no longer duplicates the bottom-bar Data tab: its segmented control is now **Today / Journal / Trends**, which makes the morning workflow easier to parse.
- The **Journal** segment now owns the morning journal and behavior-tagging surfaces, while **Today** stays action-first with plan, readiness, and sleep review.
- Tap-through metric detail sheets now exist for **Recovery**, **HRV**, **RHR**, **Sleep**, and **Strain**, with **week / month / quarter** Swift Charts ranges.
- Recovery now exposes signed contributor terms (HRV, RHR, sleep, respiration) so the detail sheet can explain *why* the score landed where it did.
- One-per-day metric history is now cached/persisted in `SessionStore`, with precomputed sparklines and precomputed chart series to keep heavy work off the render path. Today's recovery/HRV/RHR snapshot now freezes only after an overnight/morning candidate settles, then stays fixed for the rest of the day.
- The strain dial is now the labeled band gauge with a target arc and explicit optimal notch.
- Sleep detail now includes the honest HR/IMU-derived hypnogram estimate, sleep performance, and consistency.
- Notification preferences now include a dedicated **Sleep review** nudge, and the local scheduler only uses it when there is a real unconfirmed overnight candidate to review.
- A Release build was installed and verified on the physical iPhone on **June 30, 2026**; the updated Overview and `Today's Plan` hero are visible on-device with the app in a live-connected state.

Still worth follow-up:
- The new detail sheets now include a coaching/meaning `(i)` affordance, but the broader IA overlap called out in Part B still exists: **Overview / Trends / Data** sub-segments overlap with the bottom tabs and should be simplified in a separate pass.

## Current live-device findings — June 30, 2026 overnight pass

Evidence captured on the physical iPhone after an overnight wear run:
- Non-disruptive app-container pull: `artifacts/live-device/20260630-100625-overnight-pull/`
- Current Overview screenshot: `artifacts/live-device/screenshots/atria-foreground-20260630-100834.png`
- Current Vitals screenshot: `artifacts/live-device/screenshots/atria-vitals-20260630-100938.png`
- Current Data screenshot: `artifacts/live-device/screenshots/atria-data-20260630-101000.png`
- Release sleep-validation harness log: `logs/live-device/20260630T044055Z.log`

What the device is doing right now:
- The app is foregroundable, connected, and showing live HR plus strap battery on-device.
- The new `Today's Plan` hero is visible on the real phone and reads coherently in light mode.
- The home screen currently shows **Sleep 24m · Last nap**, not an overnight sleep result.
- The Vitals surface shows saved history (`4 confirmed`) but not a pending overnight confirmation flow in the visible state.

What is **not** working like WHOOP yet:
- Overnight sleep did **not** promote into a clean reviewable sleep candidate. The release harness logged:
  `ATRIADBG sleep_validation status=learning reason=sleep_motion_unvalidated_historical_stale ... source=nap_candidate ... confidence=low`.
- `sleep_auto_confirm` also logged `skipped reason=no_strong_candidate`, so there was no strong sleep candidate to confirm.
- The pulled saved-session state shows many `sleepWakeResearchReason=imu_missing` and `short_window` fragments, which matches the absence of an overnight review card on Overview.
- The current home screenshot therefore reflects the real product problem: users see a nap-like sleep tile and no obvious "review last night's sleep" card, notification, or timing-adjustment path.

Decision for the next pass:
- Priority one is **overnight sleep promotion**, not more chart polish. We need the long-wear / historical-motion pipeline to produce a strong overnight candidate that can surface as:
  1. an Overview review card,
  2. a Vitals sleep-review state,
  3. an optional phone notification only when the candidate is actually reviewable.
- Until that pipeline is reliable, Atria will continue to feel behind WHOOP on the core morning workflow even though the graph/detail UI is materially better.

## Current WHOOP product patterns worth copying — researched June 30, 2026

Current WHOOP messaging and support surfaces still center the app around **daily actionability**, not raw telemetry:
- The current App Store listing describes WHOOP as a personalized coach focused on **Sleep, Recovery, Strain, Stress, Journal, Weekly Plan, and WHOOP Coach**, with explicit promises like *Sleep Planner*, *Strain Target*, and trend drill-downs over time.
- WHOOP support still frames **Sleep Planner / Wake Alarm** as a Recovery-linked recommendation engine, not just a data screen.
- WHOOP support still frames the **Journal** as a behavior-tracking loop whose value is the recovery impact summary, sample-backed trends, and accountability.
- WHOOP support still exposes **Viewing Trends** with fixed period views rather than raw freeform graphing.

What this means for Atria's product direction:

## Live workout HUD zone/readability checkpoint - July 1, 2026

This pass tightened the active workout screen around the things a user needs while
moving: live strap HR, current HR zone, source confidence, target strain, and a
clear end action.

What changed:
- `AtriaLiveWorkoutView` now labels the screen as **Live workout** and adds a
  compact source/review strip: `Source · Strap HR` and `Review · Confirm later`.
- The HR-zone rail now shows labeled `Z0` through `Z5` segments with the current
  zone called out, matching the WHOOP-style “know the zone immediately” pattern.
- The zone focus, target strain, and source/review pills now use a local
  iOS-26 Liquid Glass surface helper instead of flat dark translucent panels.
- The destructive **End workout** action is in its own bottom slot rather than
  covering content, and the extra calories/strain stats row was removed from the
  initial HUD to reduce live-workout noise.
- No new detection math, storage, HealthKit/CoreMotion source, or phone-motion
  logic was added; this is presentation-only on top of the existing strap HR flow.

Validation:
- Static handoff checks passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Launched simulator with `--atria-show-workout --live-workout-target-hold`.
- Visual evidence: `artifacts/simulator/live-workout-glass-zone-review.png`.

Current WHOOP references checked for this direction:
- WHOOP automatic/manual activity detection and sleep/nap classification.
- WHOOP HR-zone support, which frames zones around personalized HR reserve.
- WHOOP Weekly Plan/Strain Target and Trends support pages.
- WHOOP Journal and activity-list support pages for the later confirmation flow.

## Workout false-positive dismissal memory checkpoint - July 1, 2026

This pass makes the workout-review loop less annoying when Atria sees workout-like
strap HR but the user says it was not a workout.

What changed:
- The saved workout review card now labels the negative action as **Not a workout**
  instead of the vaguer `Not this`.
- Dismissed workout-review candidate IDs are now stored in a bounded local list
  (`atria.workoutReview.dismissedIDs`, capped at 24 IDs) instead of remembering
  only one previous dismissal.
- The old single-ID key is still read as a legacy fallback, so existing dismissed
  candidates do not immediately resurface after the change.
- `refreshSavedWorkoutReviewCandidate` now checks the bounded dismissed-ID list
  before showing a review prompt.
- Added debug logging for the user-marked-not-workout path.
- No scoring, detection thresholds, HealthKit/CoreMotion source, or workout export
  metadata changed.

Validation:
- Static handoff checks passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Launched simulator with `--atria-ui-overview-segment today --atria-ui-fixture saved-workout-review`.
- Runtime UI snapshot proved `Not a workout` is a tappable button.
- Tapping the button succeeded in the simulator; the debug fixture re-injects the
  fake card, so disappearance is covered by source/static verification for the real
  candidate path.
- Visual evidence: `artifacts/simulator/workout-review-not-a-workout-memory.png`.
- Keep **Overview** action-first. The `Today's Plan` card is the right primary surface.
- Make sleep morning flow feel like a **decision point**: "Was this your sleep? adjust if needed."
- Keep trends **inside the metric detail flow**, with fixed periods and a clear baseline story.
- Prefer **behavior-to-outcome summaries** over dumping more low-level numbers onto the home screen.

## Current live-device findings — June 30, 2026 post full-protocol foreground fix

After the BLE foreground/background radio-mode patch, a second live-device pass was run on the same physical iPhone:
- Release harness log: `logs/live-device/20260630T045130Z.log`
- Updated Overview screenshot: `artifacts/live-device/screenshots/atria-foreground-20260630-1024-post-full-protocol.png`
- Updated non-disruptive evidence pull: `artifacts/live-device/20260630-102318-post-full-protocol-pull/`

What improved:
- On active foreground launch, Atria now explicitly logs:
  `ATRIADBG radio_mode mode=full_protocol persist=0 reconnect=1 reason=scene_active_interactive`
- This confirms the app no longer stays pinned in persisted `standard_hr_only` during the morning interactive pass.
- The physical Overview now surfaces a much more understandable state card:
  **Backfill ready — Atria saved the gap marker. Sync missed strap data when you are ready.**
- Preferences pulled immediately after the run show offline sync/backfill became active:
  - `offline_sync_last_status=armed`
  - `offline_range_loss_backfill_pending=1`
  - `offline_range_loss_backfill_reason=long_wear_range_loss`

What is still broken:
- Even after switching to `full_protocol`, the 25-second release harness still captured:
  - `frame_61080003_count=0`
  - `frame_61080004_count=0`
  - `frame_61080005_count=0`
  - `historical_data_rows=0`
- Sleep validation is therefore still failing the same way:
  `ATRIADBG sleep_validation status=learning reason=sleep_motion_unvalidated_historical_stale ... source=nap_candidate`
- The home screenshot still shows **Sleep 24m · Last nap** rather than an overnight review card.

Updated diagnosis:
- The **mode-selection bug is fixed**: Atria now elevates to full protocol when the user is actively in the app.
- The remaining blocker is **data acquisition after that mode switch**:
  either coexistence / reconnect churn, delayed proprietary notify start, or historical backfill not completing quickly enough to overlap the last-night window.
- Next pass should focus on why full protocol is selected but still does not yield:
  1. `0x6108` realtime frames,
  2. fresh overlapping historical gravity rows,
  3. a reviewable overnight sleep candidate.

## Current live-device findings — June 30, 2026 post proprietary-notify fallback tightening

After adding the first proprietary-notify fallback, another Release pass was run on the same physical iPhone:
- Release harness log: `logs/live-device/20260630T050721Z.log`

What the device proved:
- The app still reconnects into active foreground full protocol:
  `ATRIADBG radio_mode mode=full_protocol persist=0 reconnect=1 reason=scene_active_interactive`
- The connected strap enables at least two proprietary notify characteristics before sleep validation finishes:
  - `ATRIADBG notifyState ch=61080003-... notifying=1`
  - `ATRIADBG notifyState ch=61080004-... notifying=1`
- But the run still ends without any proprietary arm or data evidence:
  - no `ATRIADBG proprietary_arm_fallback ...`
  - no `send mode=...` command writes
  - `frame_61080003_count=0`
  - `frame_61080004_count=0`
  - `frame_61080005_count=0`
  - `historical_data_rows=0`

What this changed in the code right after the run:
- Atria now uses a shared helper so the **same immediate arm rule** is checked from both:
  - proprietary notify-state updates, and
  - the moment `txCharacteristic` becomes available.
- That closes the ordering gap where `61080003` / `61080004` could already be active, but Atria still waited on a delayed fallback because TX arrived slightly later.

Current diagnosis after the latest device evidence:
- The app is still validating sleep too early for the morning workflow:
  `ATRIADBG sleep_validation status=learning reason=sleep_motion_unvalidated_historical_stale ...`
- The most likely path now is:
  1. `61080003` / `61080004` become active,
  2. TX arrives slightly later,
  3. the app exits the verification flow before the delayed fallback runs.
- The new symmetric immediate-arm helper is the smallest safe fix for that specific race.

## Current live-device findings — June 30, 2026 post symmetric immediate-arm helper

After the helper was added and re-tested on the physical iPhone, the Release harness log moved the diagnosis forward again:
- Release harness log: `logs/live-device/20260630T051200Z.log`

What the latest timing proved:
- `sleep_validation` still fires before the BLE path is sufficiently ready:
  - `ATRIADBG sleep_validation ...` at `10:43:14.158`
  - `ATRIADBG notifyState ch=61080004-... notifying=1` at `10:43:14.172`
- `61080003` did arrive just before validation:
  - `ATRIADBG notifyState ch=61080003-... notifying=1` at `10:43:12.178`
- But because the second proprietary notify was still late, there were still:
  - no `ATRIADBG proprietary_arm_fallback ...`
  - no `send mode=...` writes
  - no `0x6108` frames
  - no fresh historical rows

Latest conclusion:
- The BLE arming race is now less about TX ordering and more about **morning sleep validation happening before proprietary BLE readiness/backfill overlap exists**.
- The next higher-value fix is no longer another BLE-arm tweak; it is to gate, retry, or defer `scheduleSleepValidationFromLaunchIfRequested(...)` until either:
  1. proprietary readiness reaches a usable threshold, or
  2. range-loss backfill / historical rows have had time to land.

## Current live-device findings — June 30, 2026 post overview IA cleanup + sleep review surfacing

Another physical-iPhone Release pass was run after the Overview IA split (`Today / Journal / Trends`), the sleep-review notification path, and a small live-HR hero readability pass:
- Release harness log: `logs/live-device/20260630T053106Z.log`
- Initial post-launch foreground screenshot: `artifacts/visual-checks/device/20260630-overview-live-hero-label-foreground.png`
- Settled follow-up screenshot: `artifacts/visual-checks/device/20260630-overview-live-hero-label-foreground-settled.png`

What this pass implemented in the UI:
- Overview sub-navigation is now **Today / Journal / Trends** instead of repeating the bottom `Data` tab.
- The hero live-HR card code now labels the surface as **Live heart rate**, shows the strap/source more explicitly, and adds a short "reading from your strap right now" explanation so the BPM number is less anonymous when that connected hero is visible.
- Sleep review now has a first-class notification kind/toggle (`sleep_review`) and the morning card copy is framed as a user decision: review detected sleep, confirm it, or adjust it.

What the physical phone showed after the change:
- The app built, installed, and relaunched cleanly on the wired iPhone.
- The top status row still came up clearly connected:
  - `Live` chip visible
  - strap battery visible (`24%`)
- The sleep tile improved materially on-device after the reconnect settled:
  - it no longer said **Last nap**
  - it now shows **Sleep · Review** with warning/review affordances in `Today at a glance`
- This is the first live-device screenshot in this handoff that visually supports the intended morning sleep-review direction instead of only showing a nap-like fallback.

What is still inconsistent on the real device:
- Even while the top row says `Live`, the large hero area above `Backfill ready` still falls back to:
  **Saved backup stays local.**
- That means the new live-HR hero labeling did land in code, but this particular connected-state path did **not** surface it in the physical screenshot because the hero itself remained in the disconnected/fallback presentation.

Updated product diagnosis from the screenshot, not just the logs:
- The sleep-review flow is now visibly moving in the right direction.
- The connected-home hierarchy is still inconsistent because the screen can simultaneously show:
  1. a live connection chip,
  2. strap battery,
  3. a fallback/disconnected hero message.
- The next pass should treat that as a product bug, not just a styling issue: align the hero-state source of truth with the top connection chips so the first card matches the live status the user already sees.

## Current live-device findings — June 30, 2026 post hero/source-of-truth alignment

The next physical-iPhone pass fixed the hero-state mismatch by making the Overview hero observe the same effective-live condition as the top status chip:
- Release harness log: `logs/live-device/20260630T053714Z.log`
- Reconnecting-state screenshot during launch churn: `artifacts/visual-checks/device/20260630-overview-live-hero-aligned.png`
- Settled live-connected screenshot after the strap resumed pulse delivery: `artifacts/visual-checks/device/20260630-overview-live-hero-aligned-settled.png`

What changed in the app:
- `AtriaHeroPanelHost` now observes the live/pulse stores directly instead of keying only off raw `statusStore`.
- The hero now treats real pulse signal / recent heart-rate samples as the same effective "connected/live" condition the top-left chip already used.
- That means a short reconnect bounce no longer leaves the disconnected fallback hero stranded on screen once live readings are present.

What the physical phone proved:
- The transient reconnect screenshot is internally consistent:
  - top chip shows `Connecting`
  - hero shows the reconnecting shell
- After the strap settled, the morning Overview now shows:
  - top chip `Live`
  - battery capsule `24%`
  - the actual **Live heart rate** hero card with `88 bpm`
  - `Backfill ready`
  - `Today / Journal / Trends`
  - `Today's Plan`
- This is the first settled live-device screenshot in this handoff where the connected hero itself is visible and readable in the actual end-user flow.

Updated product conclusion:
- The hero/source-of-truth bug is fixed enough for the current product direction: the first card now matches the status the user sees in the chrome.
- The remaining higher-value work is no longer hero consistency; it is the morning sleep-review pipeline and the long-wear/historical evidence path that still gates WHOOP-level confidence.

## Current live-device findings — June 30, 2026 post morning-flow sleep-review promotion

The next small UX pass moved the pending sleep-review card higher in the `Today` stack so it sits near `Today's Plan` instead of below `Today at a glance`:
- Release harness log: `logs/live-device/20260630T054310Z.log`
- Visual check screenshot from that pass: `artifacts/visual-checks/device/20260630-overview-sleep-review-promoted.png`

What changed in the app:
- `AtriaSleepReviewHost` now renders immediately after `Today's Plan` and before the readiness / glance section.
- This matches the current WHOOP pattern more closely: sleep review is treated as a morning decision point, not a buried archival action.
- The pending review card itself is now intentionally lighter on copy: short title, explicit time range, prominent duration, compact supporting pills, and restrained color usage so it stays inside the native Liquid Glass feel instead of reading like a diagnostic panel.
- The sleep glance tile is also calmer now: naps and pending-review states no longer inherit the normal sleep-duration grading treatment, so they read as contextual/reviewable states instead of warning-colored failures.
- `Today's Plan` has also been tightened into a faster visual summary: fewer repeated sentences, compact plan/sleep/recovery-or-baseline pills, and a shorter support line instead of stacking extra explanatory copy.

What the physical phone did during the check:
- The run relaunched successfully on the wired iPhone and re-entered the familiar reconnect path.
- The captured screen was in a **No signal / Fit check needed** state, not in the prior pending-review state.
- Because there was no active pending candidate on that capture, this screenshot does **not** visually prove the promoted review card's final above-the-fold placement yet.
- A later Release rebuild after the visual simplification also passed cleanly, but the phone still did not present a pending overnight review candidate during that validation window, so the lower-text card styling is implemented but not yet screenshot-verified in its target state.

Why this still matters:
- The code change is aligned with the desired morning workflow.
- The next time the phone surfaces a real pending overnight candidate, the review card should appear much closer to the top of Overview than before.
- Verification still needs a follow-up screenshot in a true pending-review state; until then, treat this as implemented but only partially device-verified.

## Current live-device findings — June 30, 2026 post WHOOP-inspired readability pass

A final Release rebuild/install was run on the cabled physical iPhone after tightening `Today's Plan` into a more visual, WHOOP-like decision card:
- Release harness log: `logs/live-device/20260630T060334Z.log`
- Rebuilt Overview screenshot: `artifacts/visual-checks/device/20260630-overview-whoop-inspired-rebuilt.png`
- Non-disruptive on-device state pull: `artifacts/visual-checks/device/20260630-state-pull/`

What is now visually better on the real phone:
- The top of Overview is internally consistent in the settled state:
  - status chip is `Live`
  - strap battery is live (`23%`)
  - hero shows **Live heart rate** with `61 bpm`
  - the first card still stays inside the existing Native Liquid Glass look.
- `Today's Plan` is now a visual quick-read, not a paragraph block:
  - compact readiness/baseline ring
  - single action headline: **Keep wearing today**
  - three scannable chips: `Strain`, `Sleep debt`, `Baseline`
- This is a better match to the useful part of WHOOP's home model: one morning decision surface, then supporting tiles below.

What the device proved about live readings:
- `standard_2a37_frames=3`
- `standard_2a37_rr_values=3`
- latest standard HR in the harness summary: `59`
- active journal after relaunch was fresh and reconstructable from segments.

What the device proved about sleep detection:
- The app did **not** have a pending overnight candidate to review:
  - `ATRIADBG sleep_auto_confirm status=skipped reason=no_strong_candidate source=deferred_session_load candidates=0`
  - state pull: `sleep_like_raw_windows=0`
  - state pull: `best_sleep_like_raw_status=missing`
- The local store does have sleep history, but the latest confirmed overnight is manual:
  - `confirmed_sleep_records=4`
  - `confirmed_sleep_overnights=2`
  - `latest_confirmed_sleep_source=manual_sleep`
  - `latest_confirmed_sleep_duration_text=8h00m`
- The current visible sleep tile still reflects a nap-like state rather than a reviewable overnight:
  - screenshot shows **Sleep · Last nap**
  - state pull shows `nap_like_raw_windows=11`

Product conclusion:
- The UI path for reviewing an auto-detected sleep is now in the right place and styled sanely, but this phone did not generate a strong overnight candidate during the live validation window.
- Do **not** fake a review card when `candidates=0`; that would make Atria feel less trustworthy than WHOOP.
- The next bigger sleep work should improve the detection/backfill path before more UI polish:
  1. retry/defer morning sleep validation until proprietary readiness/backfill has had time to produce overlapping evidence,
  2. promote historical archive rows only when metric-ready instead of continuity-only,
  3. repair the strap historical/IMU evidence gap so overnight windows can graduate from low-confidence fragments without relying on handset motion.

## Final live-device verification — June 30, 2026 post readability polish

One more physical-iPhone Debug build/install was run after the final readability fixes:
- Harness log: `logs/live-device/20260630T062735Z.log`
- Settled end-user screenshot: `artifacts/visual-checks/device/20260630-overview-final-device-live-settled-60s.png`
- Earlier final screenshot showing the same build before the post-relaunch reconnect settled: `artifacts/visual-checks/device/20260630-overview-final-device-live-settled.png`

What changed after the prior note:
- The live-HR hero now reconciles raw reconnect churn with recent pulse evidence, so a recent strap pulse promotes the hero to the same effective live state as the top chip.
- `Today's Plan` keeps the WHOOP-like hierarchy without changing the Native Liquid Glass thesis: one action headline, compact readiness/baseline mark, and three short chips.
- The sleep glance/review surfaces no longer use red alarm tint for nap or unconfirmed-review states. Sleep sparklines inherit the card tint, and the compact review pills use shorter labels (`Type`, `Signal`, `Eff`, `HRV`/`RHR`) so they stay readable.

What the physical phone proved:
- The final build succeeded, installed, and launched on the cabled iPhone.
- The strap produced live standard heart-rate frames:
  - `standard_2a37_frames=3`
  - `last_standard_2a37_hr=69`
  - screenshot after normal relaunch settled shows **Live heart rate 64 bpm** with strap battery `23%`.
- Atria still found no reviewable overnight candidate:
  - `ATRIADBG sleep_auto_confirm status=skipped reason=no_strong_candidate source=deferred_session_load candidates=0`
  - the visible sleep state remains **Sleep · Last nap**, so the UI is correctly not pretending there is an overnight review to confirm.
- Static handoff guardrails passed after the final code changes:
  - `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`

Final product read:
- The near-term UI/IA pass is now in a good place: clearer tabs, clearer live status, a better morning plan card, calmer sleep visuals, and detail/trend drill-downs without adding another tab.
- The remaining gap versus WHOOP is not more UI polish. It is the overnight detection/backfill pipeline producing a strong enough candidate for the review UI to appear naturally.

## Final live-device verification — June 30, 2026 sleep-readiness retry and nap truth pass

After the prior visual pass, the cabled iPhone showed a short pending candidate in the UI. That exposed a product-trust bug: Atria's review/notification logic was treating the same short, low-confidence evidence as nap-like in one place but still letting the dashboard read like sleep in another. This pass fixed that without loosening the sleep classifier or fabricating an overnight review.

New verification artifacts:
- Long Release sleep-verification harness: `logs/live-device/20260630T065113Z.log`
- Short Release reinstall/foreground harness after the final tile/card fix: `logs/live-device/20260630T065747Z.log`
- Intermediate screenshot that exposed the mismatch: `artifacts/visual-checks/device/20260630-overview-nap-review-release-settled.png`
- Final settled end-user screenshot: `artifacts/visual-checks/device/20260630-overview-nap-glance-release-settled.png`

What changed after the previous final note:
- Sleep launch validation now has bounded readiness retries instead of treating the first historical/motion-not-ready answer as final. It retries only when existing gates could improve from pending backfill or motion readiness; it does **not** lower the strong sleep candidate thresholds.
- The live-device harness parser now ignores `ATRIADBG sleep_validation status=deferred` as a completion signal, so a run must wait for a real terminal sleep-validation line.
- Short, unconfirmed sleep-candidate sources now classify as nap evidence when both duration and observed span fit the nap window.
- The sleep/nap icon mapping is now consistent: nap uses `moon.zzz.fill`, sleep uses `bed.double.fill`.
- The Today sleep glance no longer labels nap evidence as `Sleep` or applies the overnight sleep-duration zone to nap evidence.

What the physical phone proved:
- Live strap readings are healthy:
  - long run: `standard_2a37_frames=48`, `standard_2a37_rr_values=58`, `last_standard_2a37_hr=75`
  - short reinstall run: `standard_2a37_frames=40`, `standard_2a37_rr_values=42`, `last_standard_2a37_hr=82`
  - final screenshot shows **Live heart rate 85 bpm** and strap battery `22%`.
- Sleep validation now waits through the new deferred path:
  - `ATRIADBG sleep_validation status=deferred ... attempt=1 ... action=retry_existing_gates`
  - `ATRIADBG sleep_validation status=deferred ... attempt=2 ... action=retry_existing_gates`
  - final status: `status=learning`, `matched_label=nap_candidate_1_chunk`, `source=nap_candidate`, `duration_s=1576`, `confidence=low`, `motion_validated=0`.
- Notification behavior is now honest for the current evidence:
  - `ATRIADBG notification_skip kind=sleep_review reason=latest_candidate_is_nap`
- The final screenshot visually confirms the user-facing fix:
  - the card says **Review nap**
  - the time range is `9:04 AM - 9:25 AM`
  - the duration is `21m`
  - the `Type` pill says **Nap**

Remaining gap, still not UI polish:
- This device still did **not** produce a strong overnight candidate. The terminal validation reason remains `sleep_motion_unvalidated_historical_stale`, and the historical archive is still continuity-only / stale relative to this sleep window.
- The right next bigger work is still the data path: make historical/motion backfill overlap the overnight window well enough for a strong candidate, then let the existing review UI appear naturally.
- Do not fake an overnight card or notification while the best evidence is this low-confidence nap/rest fragment; that would make Atria less trustworthy than WHOOP.

Validation commands that passed in this pass:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData build`

## Follow-up pass — June 30, 2026 graph readability, nap truth, and live-device proof

This pass focused on making the data surfaces more WHOOP-like without changing Atria's Native Liquid Glass thesis: fixed-period drill-downs, clear summaries, and honest sleep/nap handling. The cabled iPhone + worn/charged strap were used again for verification.

What changed:
- Added a **Day** range to `AtriaTrendRange`, with today anchored at `calendar.startOfDay(for:)` instead of a rolling zero-day window.
- Added a compact metric-detail summary strip for each selected range. The current version uses **Latest**, **Avg**, **Range**, and **Change**.
- Kept the summary math out of SwiftUI render bodies by precomputing range summaries in `AtriaPreparedMetricHistory`.
- Added static guardrails for the new Day range, summary strip, and cached summary generation.
- Fixed a visual trust mismatch found on device: when the hero has a fresh live HR sample, the disconnected first-run overview panel can now render as live rather than saying "Connecting to your strap." A first implementation accidentally recursed inside `effectiveStatus`; the Release harness caught it as a signal-11 launch crash, and the fix is guarded by a static token requiring `effectiveStatus` to switch on raw `status`.

Physical device evidence:
- Final exact-code Release harness after the recursion fix: `logs/live-device/20260630T075056Z.log`
- Final exact-code Atria screenshot: `artifacts/visual-checks/device/20260630-atria-overview-final-exact-release.png`
- Earlier fixed-Release harness after the first recursion fix: `logs/live-device/20260630T074524Z.log`
- Earlier fixed-Release screenshot: `artifacts/visual-checks/device/20260630-atria-overview-after-effective-status-fix-release.png`
- Sleep-specific terminal validation from this pass: `logs/live-device/20260630T073624Z.log`
- The final fixed Release run built, installed, launched, and stayed alive until the harness timeout.
- Live strap data was healthy:
  - final exact run: `standard_2a37_frames=14`, `standard_2a37_rr_frames=7`, `standard_2a37_rr_values=10`, `last_standard_2a37_hr=79`
  - earlier fixed run: `standard_2a37_frames=31`, `standard_2a37_rr_frames=28`, `standard_2a37_rr_values=37`, `last_standard_2a37_hr=86`
  - `last_rr_quality_source=2a37`
  - widget snapshot completed.
- The screenshot confirms the user-facing state:
  - top chip: **Live**
  - live heart rate: **94 bpm**
  - battery: **21%**
  - `Today's Plan` remains readable and compact.
  - Today at a glance labels the sleep tile as **Nap**, **Last**, **21m**.

Sleep/nap conclusion from the actual device:
- Atria is correctly not treating the 9:04 AM short fragment as main overnight sleep.
- Terminal validation still reports:
  - `status=learning`
  - `matched_label=nap_candidate_1_chunk`
  - `source=nap_candidate`
  - `duration_s=1576`
  - `confidence=low`
  - `reason=sleep_motion_unvalidated_historical_stale`
- The sleep-review notification correctly skips while the latest evidence is nap-like:
  - `notification_skip kind=sleep_review reason=no_unconfirmed_sleep_candidate`
- The product direction stays: show the candidate, let the user adjust/confirm, and do not silently feed a low-confidence nap into overnight recovery.

WHOOP pattern references used for this pass:
- WHOOP fixed-period trend/detail behavior: `https://support.whoop.com/s/article/Viewing-Trends`
- WHOOP sleep planning/review mental model: `https://support.whoop.com/s/article/Sleep-Planner-and-Wake-Alarm`
- WHOOP journal/recovery impact framing: `https://support.whoop.com/s/article/WHOOP-Journal`

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData build`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 35 --standard-hr-only --long-wear-mode --log auto --leave-running`

## Follow-up pass - June 30, 2026 range-loss backfill ready-force proof

This pass focused on the remaining high-value blocker from the sleep-vs-nap work: Atria had a user-visible **Backfill ready** state, but automatic range-loss recovery could sit behind the normal offline-sync throttle instead of starting promptly when the user had already worn the strap through a long gap.

What changed:
- Range-loss backfill now has a short ready-force threshold (`rangeLossBackfillReadyForceInterval`, currently 90 seconds) separate from the older stale-force threshold.
- `markRangeLossBackfillRequired(reason:)` preserves the original pending timestamp when the same backfill is already pending, instead of refreshing the age on every reconnect/disconnect churn.
- `scheduleRangeLossBackfillIfNeeded(reason:)` now logs whether the request is normal, live-stream deferred, stale-forced, or ready-forced, and records whether `requestOfflineHistoricalSyncIfNeeded(...)` actually started.
- Retry scheduling is now dynamic: before the 90-second ready-force point it waits only until that point, then retries in a short 30-second cadence while pending.
- Static guardrails now protect the preserved pending-age behavior, the ready-force decision, the request-result log, and the dynamic retry helper.

Why the timestamp preservation mattered:
- The first Release run after adding ready-force still logged `ready_force=0` because a fresh reconnect reset `offline_range_loss_backfill_requested_at`.
- That meant the app could look "ready" to the user while the internal age never reached the force threshold. The follow-up patch fixed that by keeping the original pending age unless this is a newly-created backfill marker.

Physical device evidence from the cabled iPhone:
- First Release run that exposed the reset bug: `logs/live-device/20260630T085117Z.log`
- Final Release run after preserving pending age: `logs/live-device/20260630T085557Z.log`
- Screenshot from the exact post-fix app state: `artifacts/visual-checks/device/20260630-atria-backfill-force-started-release.png`
- Fresh non-invasive screenshot after the app settled: `artifacts/visual-checks/device/20260630-atria-backfill-ready-force-current.png`
- The fresh screenshot confirms the end-user state:
  - top chip: **Live**
  - hero: **Live heart rate 99 bpm**
  - battery capsule: `19%`
  - card: **Backfill ready** with a **Sync** action
  - Today at a glance still treats the short fragment as **21m** nap evidence, not main sleep.

What the final Release log proved:
- The preserved-age path reached ready-force:
  `ATRIADBG offline_sync status=requesting_range_loss_backfill ... action=force_ready_backfill ... ready_force=1`
- The force request actually started:
  `ATRIADBG offline_sync status=range_loss_backfill_request_result ... started=1 pending=1 force=1 action=force_ready_backfill`
- Offline historical sync armed in safe historical-backfill mode:
  `ATRIADBG offline_sync status=armed reason=long_wear_range_loss mode=safe_history_backfill ...`
- Historical transfer produced data instead of staying at zero:
  - `historical_2f_frames=100`
  - `historical_data_rows=100`
  - `historical_2f_candidate_rr_values=685`
  - archive update logs grew the archive to `rows=103845`
- Live RR also recovered during the same run:
  - `standard_2a37_frames=68`
  - `standard_2a37_rr_frames=59`
  - `standard_2a37_rr_values=75`
  - `last_rr_quality_source=2a37`
- The log emitted fresh sleep-motion hints from the historical path:
  - `sleep_motion_hint_count=2`
  - `sleep_motion_hint_kinds=motion_short:1,sleepflag:1`

Remaining gap:
- This proves the range-loss backfill loop can now force-start and receive historical frames on the physical phone.
- It does **not** yet prove full offline-sync completion or promotion of a strong overnight sleep candidate. The run ended before a complete final sync/validation cycle, and Atria should still avoid pretending the 9:04 AM 21-minute fragment is main sleep.
- The next pass should leave a longer Release run alive through offline-sync completion and then verify whether the newly arrived historical/motion rows overlap the actual overnight window strongly enough to surface a reviewable main-sleep candidate.

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData build`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 90 --standard-hr-only --long-wear-mode --log auto --leave-running`

Remaining gap:
- The UI is now doing the honest thing for the current device data. The unresolved high-value work is still the data/backfill path: Atria needs historical/motion coverage over the real overnight window before it can auto-detect and score main sleep with WHOOP-like confidence.

## Final live-device verification — June 30, 2026 exact review confirmation + 12h sleep truth

The user clarified the most important product edge case: there is a real difference between a nap and the main overnight sleep, and Atria must not let a 21-minute post-morning fragment masquerade as last night's sleep. This pass made the review actions operate on the exact visible card and added an adjustment path for when the human knows the window is wrong.

New verification artifacts:
- Physical Release install/live-HR harness: `logs/live-device/20260630T071436Z.log`
- Short sleep-validation harness: `logs/live-device/20260630T071717Z.log`
- Longer terminal sleep-validation harness: `logs/live-device/20260630T071813Z.log`
- Current physical-iPhone screenshot after the Release install: `artifacts/visual-checks/device/20260630-overview-after-specific-sleep-confirm-release.png`
- Settled follow-up screenshot after reconnect: `artifacts/visual-checks/device/20260630-overview-after-specific-sleep-confirm-release-settled.png`
- Prior 12-hour saved-session pull: `artifacts/visual-checks/device/20260630-sleep-12h-pull/`

What changed after the prior note:
- The Overview review card confirm action now calls `confirmSleepHistoryNightForUI(_:)`, so it saves the exact displayed nap/sleep window instead of recomputing and confirming the aggregate "best" candidate.
- The Vitals sleep-history confirm button and Morning Journal confirm button also now target the visible/latest `SleepHistorySnapshot.Night`.
- The review card has an **Adjust** action that opens `AtriaManualSleepSheet` prefilled with the detected start/end/type. This gives the user the WHOOP-like correction moment without inventing data.
- `AtriaManualSleepSheet` can now be seeded with `initialStart`, `initialEnd`, and `initialIsNap`, while still preserving manual user choice after the type toggle is touched.

What the physical phone proved:
- The cabled physical iPhone is still visible and wired:
  - device: iPhone 15 Pro, physical, wired
  - OS: iOS 27.0 build `24A5370h`
- The Release app built, installed, launched, and was left running normally after harness checks.
- Live strap HR is working, but RR was not present in the last two standard-HR-only checks:
  - `20260630T071436Z`: `standard_2a37_frames=25`, `last_standard_2a37_hr=90`, `standard_2a37_rr_values=0`
  - `20260630T071717Z`: `standard_2a37_frames=23`, `last_standard_2a37_hr=88`, `standard_2a37_rr_values=0`
  - `20260630T071813Z`: `standard_2a37_frames=27`, `last_standard_2a37_hr=103`, `standard_2a37_rr_values=0`
- The longer terminal validation still identifies the current evidence as a nap/rest fragment, not overnight sleep:
  - `status=learning`
  - `matched_label=nap_candidate_1_chunk`
  - `source=nap_candidate`
  - `duration_s=1576`
  - `confidence=low`
  - `reason=sleep_motion_unvalidated_historical_stale`
- The current screenshot visually confirms the user-facing state after Release install:
  - top state at capture time: **No signal / Fit check needed**
  - battery capsule: `21%`
  - `Today's Plan` remains a compact action card
  - Today glance labels the sleep tile as **Nap**, detail **Last**, duration **24m**
- The settled follow-up screenshot confirms the real live state after reconnect:
  - top chip: **Live**
  - battery capsule: `21%`
  - hero: **Live heart rate 107 bpm**
  - prompt: **Workout looks likely**, which is appropriate for the elevated live HR and gives the user Start / Not now control.

What the last-12-hours data actually contains:
- The saved local data does **not** contain a 4-5 hour overnight HR window for June 30.
- The relevant recent saved chunks are still:
  - `2026-06-30 02:24:59 IST -> 02:30:32 IST` (`5.6m`, avg `74`, peak `91`)
  - `2026-06-30 09:04:02 IST -> 09:25:25 IST` (`21.4m`, avg `63`, peak `83`)
  - `2026-06-30 09:25:44 IST -> 09:40:20 IST` (`14.6m`, avg `71`, peak `112`)
- There is a `6.56h` gap between the 02:30 and 09:04 chunks, so Atria cannot honestly infer the user's full overnight sleep from the current local store.
- The historical archive remains stale relative to June 30, with March/April 2026 timestamps, so it cannot validate June 30 sleep motion.

Product conclusion:
- The WHOOP-like behavior to copy here is not "pretend we know." It is: show the candidate, let the user confirm or adjust, and keep recovery/sleep effects honest.
- For this device state, Atria should keep showing the short candidate as a nap/rest fragment and let the user use **Adjust** if they want to enter the real overnight window manually.
- The next high-value implementation is still data acquisition/backfill quality for overnight windows, not more UI decoration.

Current WHOOP pattern check:
- WHOOP support still presents trends as fixed period drill-downs, so Atria should keep week/month/quarter charts inside metric detail rather than adding a graphs tab.
- WHOOP Journal behavior impact is sample-backed and recovery-linked, so Atria's local journal summaries should keep showing sample count and mean-delta instead of pretending to be cloud ML.
- WHOOP sleep surfaces remain planning/recovery-linked, so Atria should keep sleep need, debt, review/adjust, and notifications tied to real sleep candidates.

Validation commands that passed in this pass:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData build`

## Follow-up pass — June 30, 2026 trend readability and live-device recheck

This pass stayed inside the Native Liquid Glass direction and focused on making existing graph surfaces more readable instead of adding another tab or changing the visual thesis.

What changed:
- The Today **Trends** chart now shows a compact **Latest / Avg / Range / Change** summary strip above the graph.
- The Trends chart now uses a padded y-axis domain through `AtriaTrendChartScale.domain(values:)`, including resting-HR baseline when present, so small real changes do not look crushed against chart edges.
- Metric detail sheets now use the same padded y-axis helper and the same **Latest / Avg / Range / Change** summary language.
- The detail summary no longer spends a pill on **Days**; the selected segment already communicates the time window, so the visible summary now prioritizes what the user actually wants to know.
- Static guardrails now check the summary strip, shared chart-domain helper, Day range, and detail-chart padded domain.

Live-device evidence from the cabled iPhone:
- Release harness: `logs/live-device/20260630T080416Z.log`
- First screenshot after normal relaunch: `artifacts/visual-checks/device/20260630-atria-trends-summary-final-release.png`
- Settled screenshot after reconnect: `artifacts/visual-checks/device/20260630-atria-trends-summary-post-reconnect-release.png`
- The Release app built, installed, launched, stayed alive until the harness timeout, and was left running normally.
- Live strap data was healthy during the harness:
  - `standard_2a37_frames=23`
  - `standard_2a37_rr_frames=3`
  - `standard_2a37_rr_values=4`
  - `last_standard_2a37_hr=75`
  - `last_rr_quality_source=2a37`
  - widget snapshot completed.
- The settled screenshot confirms the visible live state:
  - top chip: **Live**
  - hero: **Live heart rate 89 bpm**
  - battery capsule: `20%`
  - segmented Today / Journal / Trends control remains readable.

Sleep/nap truth check from the same Release run:
- `sleep_auto_confirm` skipped with `reason=no_strong_candidate`.
- Retry state stayed `low_confidence` with `blocker=sleep_motion_unvalidated_historical_stale`.
- Candidates were present (`candidates=2`), but no ready sleep candidate existed (`ready_candidates=0`), so the 9:04 AM short fragment should remain nap/rest-like unless the user manually adjusts it.

Remaining gap:
- The exact Trends summary UI was code-built and statically guarded, but the physical screenshot is still on the Today segment. Simulator defaults were empty, so a direct Trends-tab visual capture should be done in a later UI-automation pass rather than inventing evidence here.
- The bigger product work is still overnight data coverage/backfill and smarter sleep-vs-nap classification. A 21-minute post-9 AM fragment should never silently become the main sleep when the local store has a multi-hour overnight gap.

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData build`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 35 --standard-hr-only --long-wear-mode --log auto --leave-running`

## Follow-up pass — June 30, 2026 sleep-vs-nap selector truth

This pass moved the nap/sleep distinction one layer deeper than copy. The goal was to keep Atria honest when a short morning fragment and a real overnight candidate compete, without weakening the conservative sleep detector or adding fake sleep cards.

What changed:
- Daily rollups no longer build a one-candidate sleep dictionary directly from raw aggregate candidates. They now call `preferredSleepCandidatesByDay(...)`, so duplicate same-day candidates cannot rely on dictionary insertion behavior.
- Candidate selection now prefers a multi-hour non-nap sleep window over a short nap candidate for the same sleep day, then uses motion/confidence and duration as tie-breakers.
- `confirmBestSleepCandidate`, `sleepEvidenceStatusFast`, and `sleepEvidenceStatus` now use the same preferred review candidate selector.
- `SleepHistorySnapshot.latest` now protects the shared UI/notification path: if the newest item is an unconfirmed short nap, it prefers a nearby unconfirmed main-sleep candidate inside an 18-hour review window.
- This keeps home review, Morning Journal, Vitals, and the sleep-review notification aligned because they already consume `sleepHistorySnapshot.latest`.
- Static guardrails now protect the preferred daily selector, preferred review selector, main-sleep rank, 18-hour nap-vs-main-sleep window, and the shared `latest` decision.

Live-device evidence from the cabled iPhone:
- Release harness: `logs/live-device/20260630T083953Z.log`
- Screenshot: `artifacts/visual-checks/device/20260630-atria-sleep-selector-release.png`
- The Release app built, installed, launched, stayed alive until the harness timeout, and was left running normally.
- Live strap HR worked in this exact run:
  - `standard_2a37_frames=32`
  - `last_standard_2a37_hr=87`
  - widget snapshot completed.
- RR was not present in this run:
  - `standard_2a37_rr_frames=0`
  - `standard_2a37_rr_values=0`
- The screenshot confirms the visible end-user state:
  - top chip: **Live**
  - hero: **Live heart rate 82 bpm**
  - battery capsule: `20%`
  - backfill card: **Backfill ready**
  - lower visible sleep tile still shows a short **21m** fragment, which matches the current evidence rather than pretending overnight sleep is ready.

Sleep/nap truth check from the same Release run:
- `sleep_auto_confirm` first skipped with `reason=no_strong_candidate`.
- Retry state stayed `low_confidence` with `blocker=sleep_motion_unvalidated_historical_stale`.
- Candidates were present after load (`candidates=2`), no ready sleep candidate existed (`ready_candidates=0`), and backfill remained pending (`pending_backfill=1`).

Remaining gap:
- This pass fixes candidate selection when the app has competing evidence. It does not fabricate the missing overnight evidence.
- The actual device still needs the historical/motion backfill path to overlap the true overnight window before Atria can honestly auto-detect and score main sleep like WHOOP.

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData build`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 45 --standard-hr-only --long-wear-mode --log auto --leave-running`

## Follow-up pass — June 30, 2026 sleep review classification context

This pass did not change the conservative sleep detector. It made the existing user-facing review surfaces clearer about the difference between a nap-sized candidate and the main overnight sleep.

What changed:
- Added `SleepHistorySnapshot.Night.reviewContextText` as the single shared copy source for sleep/nap consequence text.
- Nap evidence now says: **Nap-sized candidate. Not used as main sleep unless you adjust it.**
- Sleep evidence now says: **Sleep candidate. Review before it affects recovery.**
- The Today sleep review card displays the context line below the compact evidence pills.
- The Morning Journal sleep row and Vitals Sleep History card use the same context text, so the product meaning stays consistent.
- Static guardrails now protect the context property, nap-sized copy, sleep-candidate copy, home review display, Vitals footnote reuse, Morning Journal reuse, and the existing nap-notification suppression reason `latest_candidate_is_nap`.

Live-device evidence from the cabled iPhone:
- Release harness: `logs/live-device/20260630T081849Z.log`
- Immediate screenshot after normal relaunch: `artifacts/visual-checks/device/20260630-atria-sleep-review-context-release.png`
- Settled screenshot after reconnect: `artifacts/visual-checks/device/20260630-atria-sleep-review-context-settled-release.png`
- The Release app built, installed, launched, stayed alive until the harness timeout, and was left running normally.
- Live strap data was healthy:
  - `standard_2a37_frames=22`
  - `standard_2a37_rr_frames=14`
  - `standard_2a37_rr_values=23`
  - `last_standard_2a37_hr=87`
  - `last_rr_quality_source=2a37`
  - widget snapshot completed.
- The settled screenshot confirms the visible live state:
  - top chip: **Live**
  - hero: **Live heart rate 90 bpm**
  - battery capsule: `20%`
  - Today / Journal / Trends remains readable.

Sleep/nap truth check from the same Release run:
- `sleep_auto_confirm` skipped with `reason=no_strong_candidate`.
- Retry state stayed `low_confidence` with `blocker=sleep_motion_unvalidated_historical_stale`.
- Candidates were present (`candidates=2`), but no ready sleep candidate existed (`ready_candidates=0`) and backfill remained pending (`pending_backfill=1`).
- This supports the product behavior: a short post-9 AM fragment remains a nap/rest candidate, not the main sleep, unless the user adjusts it.

Remaining gap:
- The physical screenshots prove live runtime health, but the sleep review card itself was not visible in the captured viewport. The new context line is currently proven by static guardrails plus Debug/Release builds, not by a direct visual capture of that exact card.
- The larger unresolved work remains data/backfill quality over the real overnight window. UI can explain uncertainty, but it cannot honestly score overnight sleep without the missing data.

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData build`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 35 --standard-hr-only --long-wear-mode --log auto --leave-running`

## Follow-up pass — June 30, 2026 review sheet type/time clarity

This pass kept the existing safe review path but made the correction moment clearer. A detected nap/sleep opened from a review card should feel like reviewing an existing detection, not adding a brand-new manual entry.

What changed:
- `AtriaManualSleepSheet` now remembers whether it was seeded from an existing detected type.
- Seeded sheets now title themselves **Review Nap** or **Review Sleep** instead of **Add Nap/Sleep**.
- The type card now says **Detected as Nap/Sleep. Change type or window before saving.**
- If the user flips the type, the sheet says **Detected as Nap/Sleep. Saving as Sleep/Nap; adjust the window if needed.**
- This makes the WHOOP-like correction path more explicit without adding a risky one-tap “mark sleep” action that could accidentally make a 21-minute nap affect recovery.
- Static guardrails now protect the seeded review title and detected-type copy.

Live-device evidence from the cabled iPhone:
- Release harness: `logs/live-device/20260630T082806Z.log`
- Settled screenshot after reconnect: `artifacts/visual-checks/device/20260630-atria-review-sheet-copy-settled-release.png`
- The Release app built, installed, launched, stayed alive until the harness timeout, and was left running normally.
- Live strap HR worked in this exact run:
  - `standard_2a37_frames=10`
  - `last_standard_2a37_hr=87`
  - widget snapshot completed.
- RR was not present in this run:
  - `standard_2a37_rr_frames=0`
  - `standard_2a37_rr_values=0`
- The settled screenshot confirms the visible live state:
  - top chip: **Live**
  - hero: **Live heart rate 80 bpm**
  - battery capsule: `20%`
  - Today / Journal / Trends remains readable.

Sleep/nap truth check from the same Release run:
- `sleep_auto_confirm` skipped with `reason=no_strong_candidate`.
- Retry state stayed `low_confidence` with `blocker=sleep_motion_unvalidated_historical_stale`.
- Candidates were present (`candidates=2`), no ready sleep candidate existed (`ready_candidates=0`), and backfill remained pending (`pending_backfill=1`).

Remaining gap:
- The review sheet copy is proven by static guardrails and Debug/Release builds, but the physical screenshot did not capture the sheet itself. It proves exact-code runtime health, not the modal text visually.
- The bigger gap is still data acquisition/backfill over the true overnight window. The UI now makes correction clearer, but Atria still cannot honestly score main sleep until the missing overnight evidence exists.

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData build`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 35 --standard-hr-only --long-wear-mode --log auto --leave-running`

## Follow-up pass - June 30, 2026 WHOOP 6-month trends and live-device truth check

Current WHOOP pattern check:
- WHOOP's May 20, 2026 Trend Views article now explicitly calls out weekly, monthly, and 6-month trend views for Sleep, Strain, and Recovery: `https://www.whoop.com/us/en/thelocker/track-progress-with-new-trend-views/`
- That makes Atria's previous Week / Month / Quarter ranges useful but incomplete. The least risky parity move is a fixed **6M** range inside the existing metric detail chart, not a new graphs tab or a UI thesis change.

What changed:
- Added `AtriaTrendRange.sixMonths`, with `days = 180`, detail label **6 months**, and segmented-menu label **6M**.
- Added `TrendSummary.Window.oneEighty = 180` so the diagnostic/history summaries cover the same longer horizon.
- Fixed the `--atria-log-trends` launch path so the app treats trend logging as deferred launch work, then emits the trend snapshot after session load.
- Updated `live_device_debug.sh --log-trends` to require all four windows: 7, 30, 90, and 180 days.
- Static guardrails now protect the new chart range, 180-day trend summary window, app launch argument path, and harness expectation.

Live-device evidence from the cabled iPhone:
- Release harness: `logs/live-device/20260630T091823Z.log`
- Screenshot after normal relaunch: `artifacts/visual-checks/device/20260630-atria-6m-trends-release-current-final.png`
- The Release app built, installed, launched with `--atria-log-trends`, emitted trend summaries, then was left running normally.
- The trend diagnostics completed successfully:
  - `trend_summary_complete=True`
  - `trend_windows_complete=True`
  - `ATRIADBG trend_summary sessions=47 rest_hr=57 max_hr=189 windows=4`
  - `ATRIADBG trend_window days=7 ... confidence=high`
  - `ATRIADBG trend_window days=30 ... confidence=partial`
  - `ATRIADBG trend_window days=90 ... confidence=partial`
  - `ATRIADBG trend_window days=180 ... confidence=partial`
- Live strap HR worked in this exact run:
  - `standard_2a37_frames=7`
  - `last_standard_2a37_hr=89`
  - widget snapshot completed.
- RR and historical 0x2f frames were not present in this shorter standard-HR-only run:
  - `standard_2a37_rr_frames=0`
  - `historical_2f_frames=0`
- The screenshot proves the end-user app was alive and reading the strap after the Release harness:
  - top chip: **Live**
  - hero: **Live heart rate 69 bpm**
  - battery capsule: `19%`
  - backfill card: **Backfill ready**
  - bottom navigation remains Native Liquid Glass.

Sleep/nap truth check from the same Release run:
- `sleep_auto_confirm` skipped with `reason=no_strong_candidate`.
- Retry state stayed `low_confidence` with `blocker=sleep_motion_unvalidated_historical_stale`.
- Candidates were present after session load (`candidates=2`), but no ready sleep candidate existed (`ready_candidates=0`) and backfill remained pending (`pending_backfill=1`).
- This means Atria is still correctly refusing to promote the short post-9 AM fragment into main sleep. The WHOOP-like behavior to preserve is: let the user review/adjust a candidate when evidence exists, but do not let a nap-sized fragment silently affect recovery as main sleep.

Remaining gap:
- The 6M range is proven by source, static guardrails, Debug/Release builds, and Release device logs. The physical screenshot did not show the Trends detail because there is no safe `devicectl` tap path in this environment; treat it as live runtime proof, not visual proof of the 6M segmented control.
- The high-value unresolved gap is still the overnight data path. Atria needs reliable historical/motion backfill over the true overnight sleep window before it can auto-detect, notify, review, and score main sleep with WHOOP-like confidence.

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData build`
- XcodeBuildMCP `build_sim` on `iPhone 17`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 45 --standard-hr-only --long-wear-mode --log-trends --log auto --leave-running`

## Follow-up pass - June 30, 2026 sleep candidate matrix and notification truth check

This pass focused on the remaining sleep-vs-nap blocker rather than adding more UI decoration. The current device state has working live HR/RR and historical pulls, but the sleep review path still needs trustworthy timestamp-aligned motion evidence before Atria should behave like WHOOP's morning sleep review.

What changed:
- `Today's Plan` still titles the chip **Sleep debt**, but its value now prefers a concise review state when a real unconfirmed item exists:
  - **Review** for unconfirmed main-sleep evidence.
  - **Nap** for unconfirmed nap evidence.
  - Existing debt/building value when there is no reviewable unconfirmed sleep item.
- Added `ATRIADBG sleep_candidate_matrix` and per-candidate `ATRIADBG sleep_candidate` rows so live logs show every aggregate sleep/nap candidate, not just the first one.
- Added a synchronous launch-diagnostic history snapshot refresh before debug notification scheduling so notification probes do not rely on a stale placeholder snapshot.
- Static guardrails now protect the sleep chip priority, candidate matrix fields, and notification snapshot refresh order.

Live-device evidence from the cabled iPhone:
- Stronger historical/sleep probe: `logs/live-device/20260630T092933Z.log`
- Post-patch Release probe: `logs/live-device/20260630T093526Z.log`
- Screenshot after normal relaunch: `artifacts/visual-checks/device/20260630-atria-sleep-matrix-probe-current.png`
- Pulled historical archive: `artifacts/live-historical/20260630-sleep-probe/historical-archive.jsonl`
- The post-patch Release app built, installed, launched, emitted the new matrix, and was left running normally.
- The screenshot confirms the visible end-user state:
  - top chip: **Live**
  - hero: **Live heart rate 89 bpm**
  - battery capsule: `18%`
  - **Backfill ready** and **Strap battery low** cards remain visible.
  - `Today's Plan` shows **Sleep debt 5.1h**, which is correct because there is no reviewable current unconfirmed sleep item.

Sleep/nap truth check from the post-patch Release run:
- The detector still found two low-confidence candidates, but both are stale nap-sized candidates:
  - `sleep_candidate_matrix candidates=2 emitted=2 ready_candidates=0 preferred_kind=nap_candidate`
  - rank 1: `kind=nap_candidate duration_s=1576 ... auto_confirmable=0 blocker=sleep_motion_unvalidated_historical_stale`
  - rank 2: `kind=nap_candidate duration_s=1887 ... auto_confirmable=0 blocker=sleep_motion_unvalidated_historical_stale`
- `sleep_auto_confirm` still correctly skipped with `reason=no_strong_candidate`.
- `notification_skip kind=sleep_review reason=no_unconfirmed_sleep_candidate` is now understood as safe: the review model should not notify for old low-confidence nap candidates when there is no current reviewable sleep item.

Historical/backfill evidence:
- `logs/live-device/20260630T093526Z.log` captured `historical_2f_frames=92` and `historical_2f_candidate_rr_values=530`, so historical frames are flowing.
- The pulled archive had 105,421 rows; 77,731 were current-session-usable, but **0 were metric-usable**.
- The live archive status similarly reported `rows=105748 metric_usable=0 current_usable=103519 metric_ready=0 fail_closed=1`.
- The historical rows remain timestamp-misaligned for sleep scoring:
  - candidate window: June 26, 2026 around 04:33-04:59 UTC.
  - archive first/last: March 29-April 4, 2026.
  - nearest separation: about 81-83 days.
  - rows log `clock_status=clock_ref_missing`, so the existing clock-correction path cannot safely align the data yet.

Remaining gap:
- This pass made the product state and logs more honest. It did **not** solve the overnight auto-detection gap.
- The next high-value implementation should target the historical clock reference / correction path, not UI polish. Until `clock_ref_missing` becomes a real corrected timestamp reference and historical gravity overlaps the true overnight window, Atria should keep fail-closing sleep auto-confirm/recovery effects.

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- XcodeBuildMCP `build_sim` on `iPhone 17`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 95 --long-wear-mode --history-safe-backfill --verify-sleep --schedule-notifications --log auto --leave-running`

## Follow-up pass - June 30, 2026 clock-reference parsing and stale-history proof

This pass targeted the specific blocker found above: command responses were visible as generic `protocol_packet type=24` rows, but the clock parser did not consume them in the legacy/store-proprietary path used by the live-device historical probe.

What changed:
- Routed legacy `0x24` command-response payloads through the existing clock/data-range response handlers before falling back to the generic protocol-packet log.
- Added `clock_effective_unix7`, `clock_effective_age_s`, and `clock_recent_12h` to historical row logs so the sleep-vs-nap decision can prove whether strap history actually belongs to the last 12 hours.
- Updated `live_device_debug.sh` replay/summary parsing to count clock command responses from `historyClock` rows and to treat an explicit `sleep_motion_unvalidated_historical_stale` deferred state as a valid fail-closed sleep-validation outcome.
- Static guardrails now protect the legacy command-response route, freshness fields, harness clock-response counters, and harness fail-closed sleep-validation handling.

Live-device evidence from the cabled iPhone:
- Release probe: `logs/live-device/20260630T094927Z.log`
- The Release app built, installed, launched with history clock handshake, verified notifications, pulled historical rows, then was relaunched normally by the harness.
- Clock parsing is now live:
  - `historyClock status=get_clock_response seq=18 device=1782813076 wall=1782813087 drift_s=11 stale=0`
  - `historyClock status=get_clock_response seq=21 device=1782813080 wall=1782813097 drift_s=17 stale=0`
- Historical rows now use the parsed reference:
  - `clock_status=clock_ref_present`
  - `clock_corrected_unix7=1775310551`
  - `clock_effective_age_s=7502555`
  - `clock_recent_12h=0`
- Local replay of that same log through the patched harness now reports:
  - `cmd_response_count=4`
  - `history_clock_get_responses=2`
  - `history_clock_last_drift_s=17`
  - `sleep_validation_fail_closed=True`

Sleep/nap truth after the clock fix:
- The bug was not that Atria could not parse the clock anymore; that is fixed.
- The remaining truth is that the strap historical payload being served in this probe is still old by about 7.5 million seconds, roughly 86.8 days.
- Therefore Atria is still correct to refuse auto sleep confirmation, sleep-review notification, or recovery effects from these rows. A 20-30 minute stale window should remain a nap candidate at most, not last night's main sleep.

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- XcodeBuildMCP `build_sim` on `iPhone 17`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 130 --long-wear-mode --history-safe-backfill --verify-sleep --schedule-notifications --log auto --leave-running` produced the live evidence above, but the pre-patch harness summary exited with `sleep_validation_incomplete`.
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --replay-log logs/live-device/20260630T094927Z.log --verify-sleep --schedule-notifications --seconds 1` exited `0` after the harness parser fix and reported the fail-closed sleep validation state.

## Follow-up pass - June 30, 2026 live-protected backfill loop fix

This pass targeted the next blocker seen on the cabled iPhone after the clock parser fix:
when live HR is healthy, Atria can keep deferring the user-visible **Backfill ready**
state because `ready_force` was gated by `!protectedLiveStream`.

What changed:
- `scheduleRangeLossBackfillIfNeeded(reason:)` now lets the 90-second ready-force
  threshold force a range-loss backfill even while live HR is protected.
- The log now distinguishes this case as `force_ready_backfill_live_protected` so a
  future probe can prove the exact path instead of only seeing `force_ready_backfill`.
- Static guardrails now require `forceReadyBackfill = shouldForceReadyRangeLossBackfill()`
  and the new live-protected action string.

Physical device evidence from the cabled iPhone:
- Pre-patch selector/long-wear probe: `logs/live-device/20260630T100015Z.log`
- Post-patch Release probe: `logs/live-device/20260630T100520Z.log`
- The pre-patch run showed repeated live-protected deferrals and no history work:
  - `range_loss_backfill_request_result ... started=0 pending=1 force=0 action=defer_live_stream`
  - no `historyClock` responses
  - `historical_2f_frames=0`
- The post-patch Release build installed and started backfill while live-protected:
  - `offline_sync status=requesting_range_loss_backfill ... action=force_stale_backfill live_protected=1 stale_force=1 ready_force=1`
  - `range_loss_backfill_request_result ... started=1 pending=1 force=1 action=force_stale_backfill`
- Because this device's pending marker was already older than the stale threshold, the
  live run proved the forced live-protected start via `force_stale_backfill`, not the
  new `force_ready_backfill_live_protected` string specifically. The source and static
  guardrail cover the 90-second ready-force path.

Sleep/nap truth from the same evidence:
- The sleep classifier still correctly fail-closes:
  `sleep_validation status=deferred reason=sleep_motion_unvalidated_historical_stale`.
- Sleep-review notification still correctly skips:
  `notification_skip kind=sleep_review reason=no_unconfirmed_sleep_candidate`.
- Historical rows are still not fresh:
  `clock_recent_12h=0`, with ages around 7.5 million seconds.

Remaining gap:
- This fixes a loop that could keep backfill stuck behind a healthy live stream.
- It does **not** solve the stale historical window. The next useful pass should test
  the existing `0x22 -> 0x21 selector -> 0x16` path in history-only mode, then only
  promote a conservative selector into production if it produces `clock_recent_12h=1`
  rows on the physical strap.

Validation commands that passed in this pass:
- `python3 -m py_compile test_handoff_static_checks.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `bash -n live_device_debug.sh`
- XcodeBuildMCP `build_sim` on `iPhone 17`
- `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 130 --long-wear-mode --verify-sleep --schedule-notifications --log auto --leave-running`

## Follow-up pass - June 30, 2026 selector evidence and lag guard

This pass tested the exact history-selector path requested for the cabled iPhone, then stopped the run when the app became visibly laggy. The priority shifted from “collect more protocol frames” to “keep Atria responsive while preserving only the useful evidence.”

What changed:
- The old history preset was renamed to `--history-safe-backfill`; app logs now use `mode=safe_history_backfill`.
- History-selector probes preserve `cmd22=1` through the offline-sync reconnect instead of being overwritten by the safe backfill path.
- History-only probes now default to quiet BLE logs in the harness.
- `--atria-log-ble-frames` no longer enables proprietary-frame storage by itself.
- Verbose BLE frame logging is capped (`48` lines for history probes, `160` otherwise) and logs `log_budget_exhausted` when it suppresses the firehose.
- Historical sensor-research analysis is throttled during history-only probes because it does not affect sleep validation.
- Historical gravity log/analyzer keys were renamed to `historical_gravity_*`.

Physical-device evidence from the interrupted cabled-iPhone run:
- Release probe: `logs/live-device/20260630T101826Z.log`
- The run proved the selector path can now execute:
  - `offline_sync status=armed ... mode=selector_probe ... cmd22=1`
  - `historyOnly status=send_data_range cmd=22 data=00 selector_sweep=1 mode=current-unix-prefix1`
  - `data_range_response ... request_index=0 request_data=00 ... offset=56 value=1782814807`
  - `historySelector ... send cmd=21 label=current_unix_prefix1 ... data=015798436a`
  - `historySelector ... send cmd=16 label=current_unix_prefix1 data=00`
- The same run was stopped by the user because the app started lagging, then Atria was relaunched normally with `devicectl --terminate-existing com.adidshaft.atria`.

Decision:
- Do **not** promote the selector into production yet. The selector handshake is real, but the interrupted run did not prove fresh `clock_recent_12h=1` rows.
- Future physical-device history probes should use the quiet/bounded path first. If responsiveness regresses, stop the probe and keep the normal app running.

Validation after the lag guard:
- `python3 -m py_compile test_handoff_static_checks.py tools/analyze_historical_archive.py tools/analyze_gate_status.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `bash -n live_device_debug.sh`
- XcodeBuildMCP `build_sim` on `iPhone 17`
- Quiet physical-device Release install succeeded with no Atria diagnostic launch args: `logs/live-device/20260630T102925Z.log`
- The quiet harness exited with `HARNESS_ERROR=no_whoopdbg_lines_after_launch`, which is expected for a non-diagnostic launch; Atria was then relaunched normally on the cabled iPhone with `devicectl --terminate-existing com.adidshaft.atria`.
- The forbidden legacy vocabulary sweep across app/script/tests/tools/current docs returned no matches outside generated build/log folders.

## Follow-up pass - June 30, 2026 visible trend ranges

This pass tightened the Overview Trends surface toward the current WHOOP pattern:
period selection should be immediately visible, not hidden behind a menu, and graph
work should stay out of the render path.

Current WHOOP source checked for this choice:
- WHOOP's May 20, 2026 Trend Views post emphasizes weekly, monthly, and 6-month
  views across Sleep, Strain, and Recovery.

What changed:
- `AtriaTrendChartCard` now shows a visible segmented range control: `D / W / M / Q / 6M`.
- The existing metric segmented control remains directly below it, so the card reads as
  period first, metric second.
- Range filtering, summary, baseline reference, and chart domain are now prepared in
  `AtriaTrendPreparedSeries` via a refresh helper instead of recomputed as view-body
  computed properties.
- Strain trends now use `Metrics.electricStrain`, keeping effort blue instead of
  visually conflating it with warning/recovery colors.
- Static guards now forbid the old hidden range `Menu` and require the prepared-series
  path.

Validation:
- `python3 -m py_compile test_handoff_static_checks.py tools/analyze_historical_archive.py tools/analyze_gate_status.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `bash -n live_device_debug.sh`
- XcodeBuildMCP `build_sim` on `iPhone 17`

## Follow-up pass - June 30, 2026 Morning Journal action strip

Current WHOOP sources checked for this choice:
- WHOOP Journal support now frames the journal as behavior logging with recovery
  impact over time.
- WHOOP Recovery Impacts support connects journal behaviors to Recovery trends.
- WHOOP trend support keeps fixed-period trend views as drill-downs, not as a
  separate graph-first destination.

What changed:
- The Morning Journal sleep row is now a compact action strip instead of a long
  joined status sentence.
- The primary sleep value stays prominent, while `Eff`, `HRV`, and `Resp` render
  as small visual facts when present.
- The sleep confirm action moved into the sleep row itself and remains a Native
  Liquid Glass card action, so the decision is visible where the detected sleep
  context lives.
- Behavior tags remain the Journal's second step and still use the existing
  selectable glass chips.
- Static guards now protect the compact facts path, the in-row glass action, and
  the cached-input-only Morning Journal contract.

Validation:
- `python3 -m py_compile test_handoff_static_checks.py tools/analyze_historical_archive.py tools/analyze_gate_status.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `bash -n live_device_debug.sh`
- XcodeBuildMCP `build_sim` on `iPhone 17`
- Simulator app launch and screenshot captured at
  `artifacts/visual-checks/simulator/20260630-morning-journal-action-strip-settled.png`.

Visual note:
- The simulator landed on the disconnected Overview state, so the screenshot proves
  the app shell still renders after the change, but it does not visually prove the
  Journal segment because the simulator had no unlocked review/journal state. Treat
  source/build/static checks as the proof for this slice until a seeded UI capture
  or live-device Journal capture is safe to run.

## Follow-up pass - June 30, 2026 reproducible Journal visual check

This pass made the simulator visual-check path safer and more reproducible without
touching live BLE or mutating real user data.

What changed:
- Added a DEBUG-only Overview segment launch hook:
  `--atria-ui-overview-segment today|journal|trends`.
- The hook initializes the segment before `AtriaOverviewTabContent` creates its
  local `@State`, so the requested segment is stable on first render.
- The hook can render the requested Overview segment even while the simulator is
  disconnected, which avoids live-device probing for simple UI screenshots.
- Static guards now protect the bounded enum parsing, early state initialization,
  disconnected visual-check bypass, and the pass-through into `AtriaOverviewTabContent`.

Visual evidence:
- Direct launch with `--atria-ui-screen overview --atria-ui-overview-segment journal`
  initially lost to another startup path and landed on Data:
  `artifacts/visual-checks/simulator/20260630-journal-segment-action-strip.png`.
- Runtime UI automation then tapped Overview and captured the Journal segment:
  `artifacts/visual-checks/simulator/20260630-journal-segment-action-strip-visible.png`.
- The captured Journal screen shows the Native Liquid Glass shell, `Today / Journal /
  Trends` segmented control, the compact Morning Journal sleep row, and behavior
  tag chips. The simulator fixture had only saved summary sleep data, so it did
  not visually populate optional `Eff / HRV / Resp` chips or the pending confirm
  action; those remain source/static-guarded until a seeded pending-candidate
  fixture exists.

Validation:
- `python3 -m py_compile test_handoff_static_checks.py tools/analyze_historical_archive.py tools/analyze_gate_status.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `bash -n live_device_debug.sh`
- focused legacy wording sweep across app/script/tests/tools/current docs
- XcodeBuildMCP `build_sim` on `iPhone 17`

## Follow-up pass - June 30, 2026 pending sleep-review visual fixture

This pass made the Morning Journal compact action strip fully screenshot-testable in
Simulator without writing fake sleep data to the real store.

What changed:
- Added a DEBUG-only, non-persisted UI fixture:
  `--atria-ui-fixture pending-sleep-review`.
- The fixture only swaps the `sleepHistory` value passed into
  `AtriaOverviewMorningJournalCard`; it keeps behavior tags and journal counts from
  the real store and does not mutate `SessionStore` or `UserDefaults`.
- The fixture creates one pending main-sleep candidate with a 7h18m duration,
  89% efficiency, HRV 72, and respiratory rate 14.6, so the compact visual facts
  and confirm action are visible in screenshots.
- Static guards now protect the DEBUG gate, launch argument, fixture candidate
  values, `candidateCount: 1`, and no store/defaults mutation inside the fixture helper.

Visual evidence:
- Launch command used:
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen overview --atria-ui-overview-segment journal --atria-ui-fixture pending-sleep-review`
- Screenshot:
  `artifacts/visual-checks/simulator/20260630-journal-pending-sleep-review-fixture.png`
- The screenshot proves the Journal segment with Native Liquid Glass chrome, pending
  `Sleep` review, `Eff / HRV / Resp` fact chips, and the glass `Confirm sleep`
  action.

Validation:
- `python3 -m py_compile test_handoff_static_checks.py tools/analyze_historical_archive.py tools/analyze_gate_status.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `bash -n live_device_debug.sh`
- focused legacy wording sweep across app/script/tests/tools/current docs
- XcodeBuildMCP `build_sim` on `iPhone 17`

## Follow-up pass - June 30, 2026 Trends prior-period comparison

This pass copied the useful part of WHOOP's trend framing: period views should tell
the user how the current window compares with the prior window, not just draw a
raw chart.

What changed:
- `AtriaTrendChartCard` now splits the current range and the immediately prior
  same-length range inside `prepareSeries`, so the SwiftUI render path still reads
  a prepared value instead of filtering/reducing sessions in `body`.
- The summary strip stays at four cells. When prior data exists, `Change` becomes
  `Vs prior`; otherwise the existing in-range `Change` cell remains.
- Range text now formats as `58-62 bpm` / `44-58 ms` instead of repeating units on
  both sides, which keeps the phone-width chips from truncating.
- Added a DEBUG-only, non-persisted UI fixture:
  `--atria-ui-fixture trend-prior-comparison`.
- The fixture only supplies deterministic sample trend points to
  `AtriaOverviewTrendChartHost`; it does not mutate `SessionStore` or
  `UserDefaults`.
- Static guards now protect prior-period preparation, the compact range formatter,
  no render-path filtering/reducing in the trend view, and the exact-word
  placeholder wording ban.

Visual evidence:
- Launch command used:
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen overview --atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`
- Screenshot:
  `artifacts/visual-checks/simulator/20260630-trends-prior-comparison-fixture-installed.png`
- The screenshot proves the Trends segment with Native Liquid Glass chrome, fixed
  range/metric segmented controls, compact summary chips, and the new `Vs prior`
  period comparison.

Validation:
- `python3 -m py_compile test_handoff_static_checks.py tools/analyze_historical_archive.py tools/analyze_gate_status.py && python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `bash -n live_device_debug.sh`
- focused exact-word legacy placeholder sweep across app/script/tests/tools/current docs
- XcodeBuildMCP `build_run_sim` on `iPhone 17`
- Physical iPhone Release pass:
  `logs/live-device/20260630T112556Z.log`

Live-device notes:
- The Release build installed and launched on `Aman's iPhone`, then the harness left
  the app running in normal end-user mode.
- Launch timing looked healthy in the log: primary Overview ready in `4ms`,
  secondary ready in `452ms`, and trend logging completed.
- `trend_summary_complete=True` and `trend_windows_complete=True`; the 7-day trend
  window had high confidence, while 30/90/180-day windows were sparse because
  saved coverage is still only 7 days.
- The larger morning problem remains: the log still showed connection churn /
  coexistence risk, pending range-loss backfill, and
  `sleep_auto_confirm status=skipped reason=no_strong_candidate`. Treat overnight
  promotion/backfill reliability as the next product-critical pass.

## Follow-up pass - June 30, 2026 main-sleep review, Adjust, and lag-safe notifications

This pass used the cabled physical iPhone again and specifically avoided changing the
Native Liquid Glass thesis. The goal was to make the sleep/nap decision smarter and
more WHOOP-like while keeping launch/render paths calm.

What changed:
- `SleepHistorySnapshot.Night` now distinguishes short nap evidence from unconfirmed
  nap-sourced candidates that actually fit the main-sleep review window. A long or
  fragmented unconfirmed `nap_candidate` / `hr_only_nap` can surface as sleep review;
  explicit manual/auto naps remain naps.
- Morning Journal sleep review now has an `Adjust` action beside `Confirm sleep`.
  It opens `AtriaManualSleepSheet` prefilled with the detected start/end/type and
  saves via `morning_journal_adjust`, so the correction moment is visible inside the
  compact glass row instead of hidden elsewhere.
- Daily rollups now include days that only have an aggregate sleep candidate. This
  prevents overnight candidates from disappearing just because the contributing
  sessions started on the prior date.
- The notification scheduler no longer forces a synchronous full history rebuild.
  It reads the cached sleep snapshot first, then uses the bounded fast sleep-evidence
  check only to explain why review is deferred.
- Static guards now protect the review-time main-sleep promotion, Morning Journal
  Adjust path, aggregate-sleep rollup days, lag-safe notification reason, and the
  source/document placeholder wording ban.

Visual evidence:
- Simulator fixture screenshot:
  `artifacts/visual-checks/simulator/20260630-journal-pending-sleep-review-adjust.png`
- The screenshot proves the Journal segment with Native Liquid Glass chrome, pending
  `Sleep` review, `Eff / HRV / Resp` fact chips, secondary `Adjust`, and primary
  `Confirm sleep`.

Physical iPhone evidence:
- Intermediate Release probe: `logs/live-device/20260630T115223Z.log`
- Final Release probe: `logs/live-device/20260630T115502Z.log`
- The final Release build installed, launched, reached trend/sleep/notification
  diagnostics, and the harness relaunched Atria in normal end-user mode afterward.
- Launch stayed fast on the final run:
  - `home_launch_timing event=primary_ready elapsed_ms=4`
  - `home_launch_timing event=secondary_ready elapsed_ms=262`
  - no notification-time `history_snapshot_refresh` row.
- Sleep review correctly remained fail-closed:
  - `sleep_auto_confirm_retry ... candidates=2 ready_candidates=0 pending_backfill=1`
  - `notification_skip kind=sleep_review reason=sleep_candidate_pending_validation_sleep_motion_unvalidated_historical_stale`
  - `sleep_validation status=deferred reason=sleep_motion_unvalidated_historical_stale ... candidates=2 ready_candidates=0 pending_backfill=1`
- No sleep-review notification was scheduled, which is correct until historical/motion
  evidence overlaps the real overnight window.

Validation:
- `python3 -m py_compile test_handoff_static_checks.py tools/analyze_historical_archive.py tools/analyze_gate_status.py`
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `bash -n live_device_debug.sh`
- XcodeBuildMCP `build_sim` on `iPhone 17`
- Physical iPhone Release command:
  `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ATRIA_XCODE_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 55 --complete-onboarding --verify-sleep --verify-sleep-after 20 --log-trends --quiet-ble-logs --log auto --leave-running`

Remaining gap:
- This pass makes the review/notification behavior smarter and less janky. It does
  not solve the underlying overnight data gap. Atria still needs fresh historical
  motion / range-loss backfill over the true overnight window before it should
  auto-confirm, notify, or feed main sleep into recovery like WHOOP.

## Follow-up pass - June 30, 2026 Journal impacts and active charging state

This pass kept the Native Liquid Glass thesis intact and only tightened the parts
that were unclear in real use: Journal should show the useful behavior impact, and
the header should explicitly say when the strap is charging.

What changed:
- Behavior Journal now has a separate `Impacts` card. The morning tag buttons stay
  in the Morning Journal card; the lower duplicate tag grid was removed.
- Impact rows rank cached local behavior correlations by strongest effect first and
  render a compact centered bar for positive/negative HRV or Recovery movement.
- Behavior correlations now use the latest 90-day local window, with recent sessions
  and recent journal entries prepared off the render path.
- The top strap battery pill now keeps the percent visible and adds a tiny uppercase
  second line for active charger states (`CHARGING` / `FULL`) instead of relying on
  the battery glyph alone.
- Static guards now protect the 90-day correlation window, impact-strip UI, no
  render-path sort in the Journal section, explicit charging header copy, and the
  source/document placeholder wording ban.

Visual evidence:
- Simulator Journal fixture:
  `artifacts/visual-checks/simulator/20260630-journal-impact-fixture-scrolled-final.jpg`
- Physical iPhone active-charging screenshot:
  `artifacts/visual-checks/device/20260630-active-charging-header-physical.png`
- The physical screenshot shows the real connected strap reading live HR and the
  header battery pill displaying `83%` with `CHARGING`.

Physical iPhone evidence:
- Release probe log: `logs/live-device/20260630T121457Z.log`
- The cabled iPhone accepted the Release build, connected to the strap, subscribed
  to standard HR and battery, and was relaunched in normal end-user mode afterward.
- Charging was verified from the live BLE/widget path:
  - `widget_snapshot ... battery=83 charge=charging`
  - `battery level=83 source=2A19 bytes=53 persisted=1`
  - follow-up `widget_snapshot ... battery=83 charge=charging`
- The same run also proved the app was reading live data:
  - `home_launch_timing event=primary_ready elapsed_ms=10`
  - `home_launch_timing event=connected elapsed_ms=122`
  - `active_session_journal status=saved reason=first_accepted_hr_batch`

Validation:
- XcodeBuildMCP `build_run_sim` on `iPhone 17` with
  `--atria-ui-fixture journal-impact --atria-ui-overview-segment journal`
- Physical iPhone Release command:
  `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ATRIA_XCODE_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 60 --complete-onboarding --log-widget-snapshot --schedule-notifications --notification-delay 8 --quiet-ble-logs --leave-running --log auto`

Remaining gap:
- The active charging presentation is fixed. Overnight sleep still remains
  fail-closed until fresh historical/motion backfill proves the true main-sleep
  window rather than the shorter morning nap-like candidate.

## Follow-up pass - June 30, 2026 stale charging correction and strap-only steps

This pass corrects two product-trust failures found on the cabled physical iPhone:
the strap header could keep showing `CHARGING` after the charger was removed, and
steps needed to be locked to strap-derived movement evidence in every user-facing
path.

What changed:
- Cached battery level can still hydrate the percent, but cached active charging
  no longer hydrates the header. A charging label now needs current-session proof:
  direct battery-status bytes, a live battery-level increase, or 100% full.
- A flat live 2A19 battery read after a previous charging state downgrades the
  state back to level-only instead of refreshing stale `charging` evidence.
- Widget snapshots and notification battery checks now receive conservative charge
  state from the same freshness gate.
- The main Steps card and widget steps use `strapStepCount` / `strapStepText`.
- Session detection fails closed unless strap-backed activity evidence exists:
  no handset-step-only candidate, no handset-step reason text, and no handset-step
  aggregation into confirmed or aggregate workout training windows.
- Metric detail sheets also gained a compact visual summary strip plus current vs
  prior comparison bars for day/week/month style ranges, prepared off render paths.

Physical iPhone evidence:
- Release probe log: `logs/live-device/20260630T124003Z.log`
- Post-fix screenshot:
  `artifacts/visual-checks/device/20260630-strap-not-charging-strap-primary-physical.png`
- The updated Release build installed on the cabled iPhone and relaunched Atria in
  normal end-user mode afterward.
- The live widget snapshot now reports `battery=82 charge=levelOnly`, not charging,
  after the strap charger had been removed:
  - `widget_snapshot ... battery=82 charge=levelOnly`
- The screenshot shows the iPhone itself charging in the status bar while Atria's
  strap battery pill only shows `82%`, with no strap charging label.

Validation:
- `python3 -m py_compile test_handoff_static_checks.py`
- Focused static tests for battery honesty, strap-only steps, graph readability,
  and render-path caching.
- XcodeBuildMCP `build_sim` on `iPhone 17` with no warnings.
- Physical iPhone Release command:
  `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ATRIA_XCODE_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 50 --complete-onboarding --log-widget-snapshot --quiet-ble-logs --leave-running --log auto`

Remaining gap:
- The short physical run still showed `No signal` / fit-check churn from the
  coexistence path, so the next pass should keep prioritizing stable live strap
  reconnect/backfill before adding more product polish.

## Follow-up pass - June 30, 2026 live recovery grace for reconnect churn

This pass addressed the next visible trust issue from the physical phone: the
screen could briefly show `No signal` / `Fit check needed` during known reconnect
churn, even though the app was already reconnecting to the saved strap and the
diagnosis banner itself was still correctly persistence-gated.

What changed:
- `CoreLiveState` now exposes a bounded `isInRecentLiveRecovery()` flag. It is true
  only during a short known-reconnect / recent scan-match window, or while a fresh
  scan is actively recovering range-loss context. It does not hide long no-pulse
  states.
- The top status chip uses that flag to show a calmer `Reading...` / reconnecting
  state instead of jumping straight to `No signal` during the grace window.
- The live hero uses the same flag and shows `Waiting for pulse` while reconnecting,
  rather than immediately rendering the fit-check card.
- `AtriaConnectionDiagnosis.derive(...)` also respects the grace flag, so the
  inline diagnosis path stays non-visible until the no-pulse condition persists.
- Static guards now protect the recovery-grace flag, `rangeLossBackfillPending`
  publication into core live state, hero gating, and the diagnosis suppression.

Physical iPhone evidence:
- Release probe log: `logs/live-device/20260630T125243Z.log`
- Post-fix screenshot:
  `artifacts/visual-checks/device/20260630-live-recovery-grace-physical.png`
- The Release build installed and relaunched on the cabled iPhone.
- The log still captured a sub-second reconnect churn and correctly kept the
  fit-check diagnosis pending:
  - `connection_diagnosis status=pending ... title=Fit check needed delay_s=15`
  - `ble_link status=connecting reason=did_disconnect_reconnect`
- The settled physical screenshot shows the user-facing flow recovered cleanly:
  - top chip `Live`
  - strap battery `82%`
  - hero `Live heart rate` with `81 bpm`
  - no visible `Fit check needed` card

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`
- `bash -n live_device_debug.sh`
- `git diff --check`
- XcodeBuildMCP `build_sim` on `iPhone 17` with no warnings.
- Physical iPhone Release command:
  `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ATRIA_XCODE_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 45 --complete-onboarding --log-widget-snapshot --quiet-ble-logs --leave-running --log auto`

Remaining gap:
- The visual false-alarm path is calmer now, but the underlying BLE acquisition gap
  remains: the latest physical run still had no `0x6108` realtime frames and no
  fresh historical rows. The next product-critical pass should continue at the
  proprietary notify / historical backfill layer so overnight sleep review becomes
  reliable instead of merely well-presented.

## Follow-up pass - June 30, 2026 full strap-source hardening

This pass tightened the data-source boundary after the physical phone/user review
made it clear that Atria must not look like a handset-motion step product.

What changed:
- `AtriaBLEManager` no longer owns handset motion or handset step collectors.
- Home/CoreLive state no longer carries handset step count, distance, or floors,
  which also removes those redraw triggers from the connected-state dashboard.
- New session snapshots no longer encode legacy handset motion/step fields; older
  saved-session JSON still decodes because unknown keys are ignored.
- Strap-step diagnostics now log `step_source=strap_imu_research`; the old handset
  agreement helper was removed.
- HealthKit authorization no longer requests handset step reads, and the handset
  step audit was removed.
- The motion usage string was removed from `Info.plist` because the app no longer
  asks iOS for motion access.

Physical iPhone evidence:
- Release probe log after the in-place full-protocol foreground switch:
  `logs/live-device/20260630T130643Z.log`
- Final Release install/run after the strap-source hardening:
  `logs/live-device/20260630T132833Z.log`
- Final screenshot:
  `artifacts/visual-checks/device/20260630-strap-source-hardening-release.png`
- The foreground switch now stays on the existing BLE connection:
  - `radio_mode mode=full_protocol persist=0 reconnect=0 reason=scene_active_interactive`
  - `radio_mode full_protocol_discovery status=requested reason=scene_active_interactive action=keep_connection`
  - latest run: `radio_low_traffic ... custom_notify_skipped=0 custom_notify_enabled=4 ... reason=full_protocol`
- The latest widget snapshot reports live strap battery level without stale charging:
  - `widget_snapshot ... battery=81 charge=levelOnly`
- Source sweeps on the final app found no handset motion framework, handset step
  collector, HealthKit step request, or motion-permission path.
- The final screenshot shows:
  - top chip `Live`
  - strap battery `81%`
  - hero copy `Reading from your strap right now`
  - no strap charging label
- The short run still did not produce proprietary frames or fresh historical rows:
  - `frame_61080003_count=0`
  - `frame_61080004_count=0`
  - `frame_61080005_count=0`
  - `frame_61080007_count=0`
  - `historical_data_rows=0`

Remaining gap:
- The forced reconnect/stale discovery-mode issue is improved, but acquisition is
  not solved yet. The next BLE pass should focus on proprietary notify
  confirmation, command settling, and historical selector/handshake coverage until
  strap historical/IMU rows overlap the actual overnight sleep window.

## Follow-up pass - June 30, 2026 charge-state, nap clarity, and lag guard

This pass addressed three user-visible trust issues from the physical phone review:
stale active charging, a nap looking too much like the main night, and broad
live-state work contributing to dashboard lag.

What changed:
- Active strap charging now expires from the live UI unless the strap keeps proving
  it with fresh charger-status evidence or a rising 2A19 battery level. When the
  evidence ages out, Atria falls back to level-only instead of continuing to claim
  charging.
- A full battery no longer uses the powered/bolt presentation in the header. Only
  actively proven charging gets that visual.
- The sleep review notification copy now says `Review last night's sleep` and
  asks the user to confirm or adjust the sleep window. Nap-sized candidates stay
  separate from main sleep unless adjusted.
- The Today plan and Sleep history copy now call nap evidence separate from the
  main night; the visible 21-minute item is labeled `Nap`, not main sleep.
- Connection diagnosis now listens to distilled connection/contact/battery triggers
  instead of every CoreLive/PulseLive state publication. This keeps fit/range/
  low-battery warnings intact while avoiding repeated diagnosis work during normal
  live heart-rate updates.
- `AtriaMetricRing` no longer uses dashed learning rings; learning state now uses
  a quiet partial cap so the dashboard feels less diagnostic.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- XcodeBuildMCP simulator builds passed with no warnings:
  - `build_sim_2026-06-30T13-40-11-799Z_pid89703_19778fee.log`
  - `build_sim_2026-06-30T13-44-47-969Z_pid89703_3bac65ca.log`
- Physical iPhone Release install/run passed and left Atria running:
  `logs/live-device/20260630T134510Z.log`
- The fresh Release log shows fast launch and no active charging:
  - `home_launch_timing event=primary_ready elapsed_ms=5 status=connecting`
  - `launch_timing event=fast_launch_complete elapsed_ms=220`
  - `radio_mode mode=full_protocol persist=0 reconnect=0 reason=scene_active_interactive`
  - `widget_snapshot ... battery=81 charge=levelOnly`
- Final relaunched physical screenshot:
  `artifacts/visual-checks/device/20260630-atria-charge-expiry-nap-separate-lag-guard-relaunched-release.png`
- The screenshot confirms:
  - top chip `Live`
  - strap battery `81%` with no charging label
  - hero copy `Reading from your strap right now`
  - the 21-minute item is explicitly `Nap`

Remaining gap:
- This pass fixed presentation, stale charge state, and a dashboard invalidation
  smell. It does not solve the deeper proprietary/historical acquisition gap:
  the latest short Release harness still had no `0x6108` realtime frames and no
  fresh historical rows. Reliable overnight sleep review still depends on that
  BLE backfill/IMU path producing a strong main-sleep candidate.

## Follow-up pass - June 30, 2026 nap separate glance wording

This pass tightened the most visible remaining nap-vs-main-sleep ambiguity. The
main Today glance tile now keeps confirmed nap evidence labeled as a separate nap
instead of `Last`, while confirmed main sleep still uses `Last`.

What changed:
- `sleepGlanceDetailText` now returns `Separate` for confirmed nap evidence and
  `Last` only for confirmed main-sleep evidence.
- Static guards now require that nap-specific branch so a future cleanup does not
  collapse naps back into generic sleep wording.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- XcodeBuildMCP simulator build passed with no warnings:
  `build_sim_2026-06-30T13-52-23-275Z_pid89703_6590f3c9.log`
- Physical iPhone Release install/run passed and left Atria running:
  `logs/live-device/20260630T135248Z.log`
- The Release log shows:
  - `home_launch_timing event=primary_ready elapsed_ms=3 status=connected`
  - `radio_mode mode=full_protocol persist=0 reconnect=0 reason=scene_active_interactive`
  - `radio_mode full_protocol_discovery status=requested reason=scene_active_interactive action=keep_connection`
  - `widget_snapshot ... battery=81 charge=levelOnly`
  - `historical_data_rows=1`
- Physical screenshot:
  `artifacts/visual-checks/device/20260630-atria-nap-separate-release.png`
- The screenshot confirms:
  - top chip `Live`
  - strap battery `81%` with no active charging label
  - hero `Live heart rate` reading from the strap
  - the 21-minute item reads `Nap` / `Separate`

Remaining gap:
- This improves the morning interpretation of an already-saved nap. It does not
  complete overnight auto-detection. The latest run produced one provisional
  historical row, but still no `0x6108` realtime frames and no strong overnight
  main-sleep candidate.

## Follow-up pass - June 30, 2026 strap-only step source boundary

This pass removed the remaining handset-motion/step model names and ambiguous
Steps copy after physical phone/user review made the source-boundary problem
unacceptable. Atria now treats the iPhone only as BLE host/display/storage for
this feature area; movement-derived steps must come from strap IMU research.

What changed:
- Removed legacy handset motion/step fields from `SavedSession`; older JSON still
  decodes because Swift ignores unknown keys.
- Removed the inert handset motion audit lifecycle hook from `AtriaBLEManager`.
- Renamed the pure daily step aggregation types to `StrapStepSample` and
  `StrapStepSummary`.
- Changed Today and widget copy from generic `Steps` to `Strap steps`; the widget
  description now says strap-derived steps.
- Tightened the source-boundary static test so runtime Swift fails if handset
  motion/step names, motion framework imports, motion permission, or HealthKit
  step reads come back.
- Cleaned older docs/handoffs that still instructed future agents to ship or
  validate against handset steps.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- XcodeBuildMCP simulator build passed with no warnings:
  `build_sim_2026-06-30T14-02-15-274Z_pid89703_380c596d.log`
- Physical iPhone Release install/run passed and left Atria running:
  `logs/live-device/20260630T140242Z.log`
- The Release log shows:
  - `home_launch_timing event=primary_ready elapsed_ms=7 status=connecting`
  - `radio_mode mode=full_protocol persist=0 reconnect=0 reason=scene_active_interactive`
  - `widget_snapshot ... battery=80 charge=levelOnly`
- Physical screenshots:
  - `artifacts/visual-checks/device/20260630-atria-strap-steps-release.png`
  - `artifacts/visual-checks/device/20260630-atria-strap-steps-after-wait.png`
- The after-wait screenshot confirms:
  - top chip `Live`
  - strap battery `80%` with no active charging label
  - hero `Live heart rate` at `77 bpm`
  - hero copy `Reading from your strap right now`
  - nap evidence remains `Nap` / `Separate`

Remaining gap:
- This fixes the source-boundary mistake and visible strap copy. It does not
  complete overnight auto-detection or promote strap-step research; those still
  require reliable strap IMU/backfill evidence.

## Follow-up pass - June 30, 2026 Today sleep-planner strip

This pass adds a compact WHOOP-inspired sleep planning visual to Today's Plan
without changing the Native Liquid Glass direction or adding a new data source.
It turns existing saved sleep history into an actionable tonight cue instead of
only showing sleep debt as a pill.

What changed:
- `SleepHistorySnapshot.sleepPlannerTargetHours(goalHours:recoveryPercent:)`
  returns a conservative target: user goal plus capped recent debt buffer plus a
  small recovery buffer when recovery is low.
- `AtriaOverviewGuidanceSection` now shows an `AtriaSleepPlanStrip` between the
  headline and plan pills.
- The strip shows `Tonight`, an `Aim` value, a progress rail, debt, and routine
  text in one short visual row.
- The plan uses only `HeroSnapshot`, `SleepHistorySnapshot`, and `sleepGoalHours`;
  no new broad store observation or handset motion path was introduced.
- The section equality now includes `sleepGoalHours` so sleep target changes are
  not masked by the `.equatable()` wrapper.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- XcodeBuildMCP simulator build passed with no warnings:
  `build_sim_2026-06-30T14-16-30-670Z_pid89703_fdc05c11.log`
- Physical iPhone Release install/run passed and left Atria running:
  `logs/live-device/20260630T141656Z.log`
- The Release log shows:
  - `home_launch_timing event=primary_ready elapsed_ms=3 status=connecting`
  - `radio_mode mode=full_protocol persist=0 reconnect=0 reason=scene_active_interactive`
  - `widget_snapshot ... battery=80 charge=levelOnly`
- Physical screenshot:
  `artifacts/visual-checks/device/20260630-atria-tonight-sleep-plan-release.png`
- The screenshot confirms:
  - top chip `Live`
  - strap battery `80%` with no active charging label
  - hero `Live heart rate` at `80 bpm`
  - hero copy `Reading from your strap right now`
  - Today's Plan shows the new `Tonight` visual row with `Aim 9.5h`,
    `Debt 5.1h`, and `Routine --` without clipping

Remaining gap:
- This improves morning planning/readability. It does not complete overnight
  auto-detection or prove the main sleep window; that still depends on reliable
  strap IMU/backfill evidence and the review/adjust flow.

## Follow-up pass - June 30, 2026 Journal impact visual focus

This pass makes the Journal impact area more useful and more WHOOP-like without
moving behavior analytics onto the hot launch path. The section still reads
cached local summaries only, then presents the strongest signal as a compact
focus row above the existing directional bars.

What changed:
- `BehaviorJournalEntry.Tag` now carries an SF Symbol name for Sleep, Alcohol,
  Caffeine, Training, and Stress.
- `AtriaJournalImpactStrip` now promotes the first cached summary into an
  `AtriaJournalImpactFocus` row with a small progress ring, tag icon, metric
  delta, and local-day count.
- `AtriaJournalImpactBar` now includes the same tag icon so the rows scan faster
  without adding color noise or changing the Liquid Glass card thesis.
- Static guards now require the focus row and icon path while still forbidding
  Journal-time sorting/recomputation.

Validation:
- XcodeBuildMCP simulator build/run passed with no warnings:
  `build_run_sim_2026-06-30T14-31-56-074Z_pid89703_f485ab80.log`
- Physical iPhone Debug fixture launch succeeded for the top Journal surface:
  `artifacts/visual-checks/device/20260630-atria-journal-impact-fixture-debug.png`
- Simulator layout screenshot for the offscreen impact card:
  `artifacts/visual-checks/device/20260630-atria-journal-impact-fixture-sim.jpg`
- The simulator runtime snapshot saw the new accessible focus and rows:
  - `Top behavior signal. Sleep. HRV +6 ms. 9 tagged days · local correlation.`
  - `Sleep` / `HRV +6 ms`
  - `Training` / `HRV +3 ms`
  - `Caffeine` / `HRV -4 ms`
- The physical iPhone was restored to Release afterward and relaunched normally:
  `artifacts/visual-checks/device/20260630-atria-release-restored-after-journal-fixture.png`
- The restored Release screenshot confirms:
  - top chip `Live`
  - strap battery `80%` with no active charging label
  - hero `Live heart rate` at `87 bpm`
  - hero copy `Reading from your strap right now`
  - Today's Plan still shows the `Tonight` row and nap evidence remains
    `Nap` / `Separate`

Remaining gap:
- The Journal visual is improved and off the launch path. This still does not
  solve the deeper overnight auto-detection/backfill gap; the physical Release
  restore installed and launched successfully, but the short console capture did
  not emit `ATRIADBG` lines before timeout, so the app was relaunched normally
  with `devicectl` and verified by screenshot.

## Follow-up pass - June 30, 2026 short nap vs overnight classifier guard

This pass tightens the sleep/nap classifier at the model layer. Current WHOOP
patterns still make the morning sleep review and Sleep Planner the key daily
decision point, so Atria should not let a short morning/overnight low-HR chunk
masquerade as a nap before a stronger overnight candidate gets considered.

What changed:
- `aggregateSleepCandidates` now computes an explicit
  `clusterOvernightReviewWindow` and `clusterDaytimeNapWindow`.
- `shortLowHRNapCandidateReady` now requires `clusterDaytimeNapWindow`, so a
  single short low-HR cluster ending in the overnight/morning review window no
  longer becomes `nap_candidate` solely because it is short and low HR.
- Daytime nap candidates still work in the 11:00-20:00 local window.
- Static guards now require the explicit overnight-vs-daytime split so this
  cannot silently regress.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- XcodeBuildMCP simulator build passed with no warnings:
  `build_sim_2026-06-30T14-43-00-558Z_pid89703_9313c013.log`
- Physical iPhone Release build, install, and normal launch passed via direct
  `xcodebuild`/`devicectl`.
- Physical screenshot:
  `artifacts/visual-checks/device/20260630-atria-sleep-classifier-release.png`
- The screenshot confirms:
  - top chip `Live`
  - strap battery `80%` with no active charging label
  - hero `Live heart rate` at `88 bpm`
  - hero copy `Reading from your strap right now`
  - Today's Plan remains readable with the `Tonight` sleep target row

Remaining gap:
- This prevents one bad upstream label. It does not by itself prove overnight
  auto-detection, because the app still needs reliable strap IMU/backfill rows
  to produce a strong main sleep candidate.

## Urgent checkpoint - June 30, 2026 gym auto-workout readiness

Decision:
- Safe enough to take to the gym for diagnostic auto-workout capture.
- Do not treat this as a guaranteed automatic workout save yet; the live
  Release check was resting HR, so the detector correctly stayed in learning
  until duration and elevated-HR gates are met.

Release device evidence:
- Physical iPhone Release build and install passed via direct `xcodebuild` and
  `devicectl`.
- Live-device checkpoint log:
  `logs/live-device/20260630T144900Z-gym-checkpoint-release.log`
- Final running screenshot:
  `artifacts/visual-checks/device/20260630-atria-gym-checkpoint-release-running.png`
- Process proof after relaunch:
  `67560 ... /Atria.app/Atria`

What the log proved:
- Strap-only mode was armed:
  `radio_mode mode=standard_hr_only ... reason=launch_arg`
- The standard BLE heart-rate characteristic was notifying:
  `notifyState ch=2A37 notifying=1 err=nil`
- Battery came from the strap battery characteristic and was not stale charging:
  `battery level=79 source=2A19` and widget `charge=levelOnly`
- Live HR samples were accepted from the strap with clean continuity:
  `hr_raw_2a37=53 hr_accepted=53 hr_zero=0` and
  `stream_coverage_percent=100`
- Workout auto-save was armed:
  `workout_auto_save schedule interval_s=15.0 ... threshold_hr=123`
- The preflight gates were explicit:
  `min_duration_s=600 min_elevated_s=300 min_bout_s=180`
- The resting checkpoint correctly did not auto-save:
  `status=learning reason=duration_below_10m ... hr_below_threshold`
- Active capture was checkpointed to storage:
  `session_store_save status=ok op=checkpoint sessions=48`

Safest unplug state:
- Atria was relaunched outside the timed harness with:
  `--atria-standard-hr-only`, `--atria-long-wear-mode`,
  `--atria-checkpoint-session-every 60`, `--atria-log-live-workout-every 15`,
  and `--atria-auto-save-workout-when-ready 15`.
- Screenshot confirms the app is foregrounded with `Live`, strap battery `79%`,
  and `Live heart rate 70 bpm` from `Strap`, with no strap charging label.

Remaining gap:
- The next definitive proof is a real elevated-HR workout where HR crosses the
  current `123 bpm` threshold long enough to emit
  `workout_auto_save status=saved`. Until then, the app is safe for diagnostic
  capture, but not proven as a guaranteed unattended workout logger.

## Follow-up pass - June 30, 2026 trends period readout

This pass makes the Trends surface more readable without adding another graph
tab or putting rollups on the render path. The chart still uses cached
`overviewTrendPoints`, but now adds a compact period takeaway above the metric
chart.

What changed:
- `AtriaTrendChartCard` now prepares a cached `AtriaTrendPeriodReadout` whenever
  the selected period or source points change.
- The visible Trends card can now say things like `Strain-heavy month`,
  `Recovery needs care`, `Recovery-led month`, or `Steady month` based on
  current vs prior-period HRV, RHR, and strain averages.
- The readout shows three compact chips for HRV, RHR, and Strain deltas, so the
  user gets the weekly/monthly takeaway before reading the line chart.
- `TrendSummaryView` in History now also has a selected-window focus card and
  compact window chips, replacing the dense stacked summary rows.
- Static guards now require the prepared period readout, selected-window focus,
  and prebuilt chart models so the UI cannot silently regress into number soup.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- Swift source sweep found no handset-motion or HealthKit step source strings.
- Simulator Debug build passed on iPhone 17 Pro.
- Visual check:
  `artifacts/visual-checks/simulator/20260630-atria-overview-trends-period-readout.png`
- The screenshot confirms:
  - Overview `Trends` segment is selected.
  - The chart now leads with `Strain-heavy month`.
  - HRV, RHR, and Strain deltas are visible in compact chips.
  - The existing metric picker and chart remain visible below without clipping.

## Follow-up pass - June 30, 2026 sleep review decision point

This pass makes detected sleep/nap review behave more like a morning decision
point instead of a buried archive action.

What changed:
- `AtriaSleepReviewHost` now supports the existing `pending-sleep-review`
  DEBUG fixture directly, so the top Overview review card can be visually
  checked without needing live overnight data.
- Pending sleep review now appears above `Today's Plan` when present, so the
  user sees the detected window before it affects the rest of the morning flow.
- `AtriaSleepReviewCard` was simplified into a more visual review card:
  duration, start/end/signal chips, an impact strip, and the three actions
  `Confirm`, `Adjust`, and `Not me`.
- Sleep vs nap consequences are now explicit:
  sleep says `Affects recovery`, while naps stay separate unless adjusted.
- Vitals sleep history no longer forces a direct confirm-only path. Pending
  candidates now expose `Review sleep/nap` and open the existing adjustable
  `AtriaManualSleepSheet`; quick `Confirm` remains available.
- Sleep-review notifications now schedule for nap candidates too, with nap-
  specific copy, while preserving dismissed/already-notified guards.
- Static checks now guard the Overview timeline/impact strip, the Vitals
  adjustable review path, and the nap notification behavior.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- Swift source sweep found no handset-motion or HealthKit step source strings.
- Simulator Debug build passed on iPhone 17 Pro.
- Visual check:
  `artifacts/visual-checks/simulator/20260630-atria-sleep-review-card-v4.png`
- The screenshot confirms:
  - `Review sleep` appears above `Today's Plan`.
  - The detected window shows `12:00 AM - 7:18 AM` and `7h 18m`.
  - Start, End, and Signal chips are visible.
  - The impact strip says `Affects recovery`.
  - `Confirm sleep`, `Adjust`, and `Not me` are visible without clipping.

## Follow-up pass - June 30, 2026 journal tag loop clarity

This pass makes the Journal segment feel more like a daily feedback loop and
removes a banned symbol that had drifted back into source.

What changed:
- `AtriaOverviewMorningJournalCard` now shows a compact `Tag today` strip above
  the tag grid. It explains what to do before the user sees the checkbox-like
  tag buttons.
- When tags are selected, the strip becomes a `logged today` state with compact
  tag icons, keeping the current-day state visually obvious.
- The Journal impact empty state no longer uses the banned `sparkles` symbol.
- Insights and REM stage glyphs now use non-banned symbols.
- Static checks now guard the Journal tag strip and assert Swift sources do not
  contain the banned symbol string.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- Swift source sweep found no banned symbol, fallback material, handset-motion,
  or HealthKit step source strings.
- Simulator Debug build passed on iPhone 17 Pro.
- Visual check:
  `artifacts/visual-checks/simulator/20260630-atria-journal-tag-strip.png`
- The screenshot confirms:
  - Overview `Journal` segment is selected.
  - The Morning journal card shows the existing sleep review.
  - The new `Tag today` strip is visible above the tag buttons.
  - The copy reads `Tap what happened and Atria compares it locally.`

## Follow-up pass - June 30, 2026 trend action readout

This pass makes the Trends chart feel less like a data panel and more like a
WHOOP-style coaching surface: the selected metric/range now gets a compact
action readout before the raw chart.

What changed:
- `AtriaTrendChartCard` now derives an `AtriaTrendActionReadout` while preparing
  the selected chart series, keeping trend interpretation off the SwiftUI render
  path.
- The readout turns the selected metric/range into a visual cue such as `HRV
  lifting`, `RHR elevated`, or `High-load range`, with one short next-step line.
- The card stays inside the existing Trends surface and uses the current
  Native Liquid Glass card language; no new tab or extra navigation was added.
- Static checks now guard the action readout, card, symbols, and representative
  metric states.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- Swift source sweep found no banned symbol, fallback material, handset-motion,
  or HealthKit step source strings.
- Simulator Debug and Release builds passed on iPhone 17 Pro.
- Visual checks:
  `artifacts/visual-checks/simulator/20260630-atria-trends-action-readout.png`
  and
  `artifacts/visual-checks/simulator/20260630-atria-trends-action-readout-light.png`
- The screenshots confirm:
  - Overview `Trends` segment is selected.
  - The period readout remains visible.
  - The selected metric now shows the compact action card (`RHR steady` in the
    fixture).
  - The older four-pill range strip no longer stacks above the chart when the
    action readout is available.
  - Dark and light mode are both legible.

## Follow-up pass - June 30, 2026 sleep sync needed state

This pass improves the morning trust state when last night's sleep is not yet
reviewable because missed strap data still needs to sync.

What changed:
- Overview now shows a compact `Sync sleep data` card above `Today's Plan`
  only when range-loss backfill is pending and there is no reviewable sleep/nap
  candidate.
- The card connects the existing backfill flow to the morning sleep decision:
  pull missed strap data first, then review sleep if Atria finds it.
- Pending sleep review still wins; the card does not appear when Atria already
  has a candidate to confirm or adjust.
- A DEBUG fixture (`sleep-sync-needed`) was added for visual checks.
- Static checks now guard the honest gating and the user-facing copy.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- Swift source sweep found no banned symbol, fallback material, handset-motion,
  or HealthKit step source strings.
- Simulator Debug and Release builds passed on iPhone 17 Pro.
- Visual checks:
  `artifacts/visual-checks/simulator/20260630-atria-sleep-sync-needed.png`
  and
  `artifacts/visual-checks/simulator/20260630-atria-sleep-sync-needed-light.png`
- The screenshots confirm:
  - Overview `Today` segment is selected.
  - `Sync sleep data` appears above `Today's Plan`.
  - The card shows Sync `Ready`, Sleep `Waiting`, and Review `If found`.
  - The existing top `Backfill ready` Sync action remains available.
  - Dark and light mode are both legible.

## Follow-up pass - June 30, 2026 workout detection visual prompt

This pass makes the live workout auto-detection prompt easier to act on without
changing the conservative detector thresholds.

What changed:
- `AtriaWorkoutDetectionBanner` now leads with a circular effort/evidence rail
  instead of a long explanatory paragraph.
- The prompt copy is shorter: `Workout detected?` and `Start tracking to group
  this effort for review.`
- The evidence pills remain local strap-derived signals: confidence, live heart
  rate, bpm above rest, strain, and readings.
- The existing `Start workout` and `Not now` actions are unchanged.
- A DEBUG fixture (`workout-detection`) was added for visual checks.
- Static checks now guard the conservative thresholds, visual rail, fixture, and
  removal of the older text-heavy copy.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- Swift source sweep found no banned symbol, fallback material, handset-motion,
  or HealthKit step source strings.
- Simulator Debug and Release builds passed on iPhone 17 Pro.
- Visual checks:
  `artifacts/visual-checks/simulator/20260630-atria-workout-detection-prompt.png`
  and
  `artifacts/visual-checks/simulator/20260630-atria-workout-detection-prompt-light.png`
- The screenshots confirm:
  - The inline prompt shows `Workout detected?` above the Overview content.
  - The circular evidence rail and Start workout / Not now actions are visible.
  - The confusing duplicate state badge is gone.
  - Dark and light mode are both legible.

## Follow-up pass - June 30, 2026 journal impact top signal

This pass makes behavior-to-recovery/HRV impact easier to scan, closer to the
WHOOP Journal pattern of showing behavior impacts rather than generic notes.

What changed:
- `BehaviorCorrelationSummary` now exposes an `impactToneText` value:
  `Linked up`, `Linked down`, or `Learning`.
- `AtriaJournalImpactFocus` now shows that tone as the lead chip and enlarges
  the metric delta, replacing the generic `Top signal` label.
- The underlying correlation logic is unchanged and remains local mean-delta
  only; no cloud, no ML claim, and no recomputation in SwiftUI render paths.
- Static checks now guard the linked-tone copy and the off-render-path behavior
  summary cache.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  `91` checks.
- `python3 -m py_compile test_handoff_static_checks.py` passed.
- `git diff --check` passed.
- Swift source sweep found no banned symbol, fallback material, handset-motion,
  or HealthKit step source strings.
- Simulator Debug and Release builds passed on iPhone 17 Pro.
- Visual checks:
  `artifacts/visual-checks/simulator/20260630-atria-journal-impact-linked-signal.png`
  and
  `artifacts/visual-checks/simulator/20260630-atria-journal-impact-linked-signal-light.png`
- The screenshots confirm:
  - The focused Journal fixture shows the Impacts card directly.
  - The top behavior now reads `Linked up`, `Sleep`, and `HRV +6 ms`.
  - The local impact bars remain visible for Sleep, Training, and Caffeine.
  - Dark and light mode are both legible.

## Live-device gym finding - June 30, 2026 workout collection continuity

The user's real gym session was roughly **20:45-22:25 IST**: a short walk,
then chest, triceps, and abs. A non-disruptive physical-iPhone pull after the
session showed that Atria did **not** honestly capture or confirm the full
workout. Treat this as a product-quality bug, not a UI polish issue.

Evidence:
- Pull directory:
  `artifacts/live-device/20260630T171622Z-gym-workout-pull/`
- Atria was running after the pull, connected to the strap, and the battery
  state was live/not stale:
  - `battery_level=76`
  - `battery_charge_status=notCharging`
  - `battery_is_charging=0`
  - `battery_source=live_2A19`
- No confirmed workout exists for the **20:45-22:25 IST** window.
- The only saved workout-like HR evidence in that window was fragmented into
  three long-wear chunks:
  - `20:47:53-20:53:39`, `346s`, `349` samples, avg `113`, peak `129`
  - `21:03:18-21:09:36`, `377s`, `352` samples, avg `138`, peak `164`
  - `21:50:40-21:59:48`, `548s`, `487` samples, avg `123`, peak `146`
- Total observed HR samples in-window: `1188`.
- Maximum gap between samples: about `41 minutes`.
- Observed coverage of the 100-minute workout window was only about `20-22%`,
  depending on the continuity cap.

Root cause fixed in this pass:
- Foreground interactive mode was accidentally blocking the event-driven
  checkpoint path:
  `guard !foregroundInteractiveMode else { return }`
- That was wrong. If the user keeps Atria open during a workout, foreground
  mode must save strap-only checkpoints, not pause them.
- `checkpointFromLiveEventIfNeeded(now:)` now runs in foreground and labels
  those saves as `Live foreground checkpoint`.
- Foreground event-driven checkpoint cadence now uses the configured long-wear
  interval, normally `60s`; unattended/background still keeps the conservative
  minimum floor.
- The checkpoint log now includes
  `source=ble_event app_state=%@ foreground_interactive=%d interval_s=%.0f`
  so future device runs can prove whether foreground collection is alive.
- Pending range-loss backfill was also allowed to force a historical sync while
  live strap HR was protected. That can disconnect/reconnect the strap. It now
  defers while `shouldProtectLiveStreamForOfflineSync()` is true instead of
  forcing `ready`/`stale` backfill through an active collection window.

Important boundary:
- This fix is strictly about saving strap HR continuity. Do **not** solve this
  by adding iPhone motion, CoreMotion steps, HealthKit steps, GPS, or phone
  activity classification. Atria is a WHOOP-strap product; workout collection
  must remain strap-derived.

Product follow-up: workout review + exercise learning:
- Detection should create a local `WorkoutReviewCandidate` from strap evidence:
  start/end, observed coverage, average/peak HR, strain delta, confidence, and
  fragmentation summary.
- If evidence is strong and continuous, show a confirmation card:
  `Workout detected` -> `Confirm`, `Adjust time`, `Not a workout`.
- If evidence is fragmented but workout-like, show it as reviewable evidence,
  not an auto-confirmed workout. The user can stitch/adjust the window.
- After confirmation, ask what the user did with a searchable local exercise
  selector. Include broad workout types plus a comprehensive strength catalog
  for common chest, triceps, abs, legs, back, shoulders, biceps, cardio, sport,
  mobility, and mixed sessions.
- Save selected exercises on `UserConfirmedWorkout`; let Atria learn local
  priors from the user's confirmed labels and strap-only patterns. This is a
  personalization aid, not a cloud ML claim.
- Recovery/strain should only incorporate confirmed workouts or candidates
  that pass the existing continuity gates. Fragmented evidence can inform a
  review prompt, but it should not silently alter recovery as if the full
  workout was captured.

Validation status for this pass:
- Static guards were added for the foreground checkpoint path, log token, and
  live-stream-protected backfill deferral.
- Simulator Debug and generic iOS Release builds passed after the fix.
- A physical Release build was installed/launched on the cabled iPhone and
  left running. The first smoke proved live strap reconnect and live
  `notCharging` battery state; a longer foreground-checkpoint smoke should be
  inspected for the new `foreground_interactive=1` checkpoint line before this
  section is considered fully device-proven.

## Follow-up pass - June 30, 2026 workout review prompt labels

This pass moves the live workout prompt closer to the WHOOP-style review
moment without pretending Atria can classify exercises from the phone.

What changed:
- The inline prompt now leads with **Review this effort** instead of a generic
  live-tracking banner.
- The subtitle is shorter and more honest: strap HR looks workout-like, and the
  user can confirm or adjust later.
- The visual rail remains strap-derived: live HR above rest plus strain.
- A compact **Likely labels** area now shows broad local suggestions like
  `Strength`, `Cardio`, `Mixed` plus exercise chips like `Chest`, `Triceps`,
  and `Abs`.
- The primary action is now **Track + review**, which better matches the desired
  flow: keep collecting now, then let the user confirm/label the workout.
- This is still a UI/review prompt only. It does not silently auto-confirm a
  fragmented workout and does not use iPhone motion, HealthKit steps, GPS, or
  CoreMotion.

Validation:
- Static guardrails now protect the review title, strap-HR wording, likely
  label/exercise chips, and removal of the older `Track live` / `Review later`
  copy.
- Simulator visual checks:
  `artifacts/visual-checks/simulator/20260630-atria-workout-review-labels.png`
  and
  `artifacts/visual-checks/simulator/20260630-atria-workout-review-labels-light.png`
- The screenshots confirm the card is visible in the Overview `Today` segment,
  uses the current Native Liquid Glass chrome, shows strap-only evidence, and
  presents Strength/Cardio/Mixed plus Chest/Triceps/Abs review chips in dark
  and light mode.

## Follow-up pass - June 30, 2026 guided workout review flow

This pass turns the workout prompt into an actual user-led review flow instead
of a single view full of choices.

What changed:
- Added a guided `AtriaWorkoutReviewFlow` sheet with separate steps:
  1. **Time** - confirm or adjust start/end.
  2. **Type** - choose a workout label.
  3. **Exercises** - only appears for strength/HIIT/functional sessions.
  4. **Save** - final review before confirmation.
- Added broad activity types inspired by WHOOP-style activity review:
  Strength, Cardio, Running, Walking, Cycling, HIIT, Functional, Yoga, Pilates,
  Dance, Sport, Swimming, Rowing, Mobility, and Other.
- Added a large local exercise catalog grouped by body area / modality:
  Chest, Back, Shoulders, Biceps, Triceps, Legs, Glutes, Core, Machines, and
  HIIT.
- Exercise selection has search and selected chips. It is not dumped into the
  first view.
- Confirmed workouts now persist human review semantics:
  `activityType`, `activitySubtype`, `exerciseNames`, and `reviewSource`.
- The save path still uses `confirmWorkoutWindowForUI(...)` and keeps the
  existing strap-HR evidence gates. User review annotates the workout; it does
  not bypass the detection source boundary.

Validation:
- Static guardrails protect the flow steps, activity types, exercise catalog,
  persisted workout review fields, and `guided_workout_review` save source.
- Simulator visual checks:
  - `artifacts/visual-checks/simulator/20260630-atria-workout-review-flow-time.png`
  - `artifacts/visual-checks/simulator/20260630-atria-workout-review-flow-type.jpg`
  - `artifacts/visual-checks/simulator/20260630-atria-workout-review-flow-exercises.jpg`
  - `artifacts/visual-checks/simulator/20260630-atria-workout-review-flow-summary.jpg`
- UI automation proved the user can move from Time -> Type -> Exercises ->
  Summary and select an exercise before saving.

## Follow-up pass - June 30, 2026 saved workout review notification + elegance

This pass addresses the gym-run trust gap: stitched strap-HR evidence can be
reviewable after the workout, so Atria should bring the user into confirmation
instead of silently leaving evidence in diagnostics.

What changed:
- Added `WorkoutReviewCandidate` from saved strap-HR evidence. It uses the
  existing replay/stitching detector and does not lower workout gates or add
  phone-motion sources.
- Overview now surfaces an after-the-fact workout review card when a saved
  candidate is ready/near-miss/strength-like and not already confirmed.
- Local notifications now include a user-toggleable **Workout review** decision:
  `Workout ready to review` / `Effort ready to review`, with duration, time
  window, and peak strap HR.
- Notification scheduling remembers the last workout candidate and respects a
  local dismissed-candidate key to avoid repeating the same review prompt.
- `AtriaNotificationSettings` now decodes older saved settings without dropping
  user preferences; the new workout-review toggle defaults on.
- Confirmed workout HealthKit export now maps the user's selected type to
  appropriate `HKWorkoutActivityType` values where possible, and includes
  Atria metadata for activity type, subtype, exercises, exercise count, and
  review source.
- The workout review sheet was tuned back toward elegant Native Liquid Glass:
  restrained strap signal mark, compact progress chips, compact activity
  chooser, and native glass Back/Continue buttons with no card slab behind
  them.

Validation:
- Static guardrails now protect saved review candidates, workout-review
  notifications, notification preferences, rich HealthKit metadata, activity
  type mapping, and the no-footer-card rule for the review flow.
- Debug simulator build passed.
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.

## Overnight sleep review candidate checkpoint - July 1, 2026

This pass fixes the wake-up trust gap from the physical iPhone overnight run:
Atria had captured an 8h10m continuous strap-only overnight session, but it
kept reporting no strong sleep candidate because the review gate required both
low average HR and a low enough peak HR.

What changed:
- Long continuous overnight HR-only sessions can now become review candidates
  when they are not workout-ready, even if motion validation is unavailable.
- Auto-confirm remains strict: motion-validated candidates only. HR-only
  overnight sleep still requires user review before it unlocks recovery.
- Sleep-review notifications now prefer the direct review candidate before a
  stale cached snapshot, so a detected overnight window is not suppressed by
  `sleep_motion_unvalidated_historical_stale`.

Physical-device validation:
- Release built, installed, and launched on Aman's physical iPhone
  `3803F5B6-1666-56D3-A71A-62F131F6CE3B`.
- Pre-patch pull showed the overnight data was captured:
  `2026-07-01 00:33:01 IST` to `08:43:29 IST`, `30,585` HR points,
  `23,567` RR points, and zero accepted HR gaps.
- Post-patch Release log:
  `logs/live-device/sleep-review-notification-fix-20260701-085332.log`.
- Evidence:
  - `sleep_auto_confirm status=skipped reason=no_strong_candidate` remains
    correct.
  - `sleep_review_candidate ... candidate_source=sleep_window ... duration_s=29608`
    now appears.
  - `notification_scheduled kind=sleep_review ... title=Review detected sleep`
    now appears.
  - `notification_delivered kind=sleep_review ... foreground=1` confirms
    delivery during the device run.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.

## High-stakes physical-device accuracy checkpoint - July 1, 2026

The user asked to skip low-stakes polish and focus on accurate strap reading and
representation. This checkpoint used the cabled physical iPhone non-disruptively
first, so the running BLE session was not killed before evidence was copied.

Physical-device evidence:
- Device: Aman's physical iPhone 15 Pro,
  `3803F5B6-1666-56D3-A71A-62F131F6CE3B`, available/paired.
- Pull artifact:
  `logs/device-pulls/high-stakes-20260701-145308/`.
- Pull mode: `non_disruptive_copy_only`; Atria process was running.
- Official WHOOP process was not listed during the pull, reducing coexistence
  risk for this checkpoint.
- Strap source boundary remained clean in pulled data:
  `phone_motion_sessions=0`, `phone_motion_nonzero_sessions=0`, and the local
  static guard still rejects CoreMotion/HealthKit step-count sources.
- Live strap battery was usable and correctly not charging at pull time:
  `battery_level=64`, `battery_source=live_2A19`,
  `battery_charge_status=notCharging`, `battery_is_charging=0`,
  `battery_drop_recent=1`.

Sleep truth from the morning pull:
- Atria detected the real overnight candidate:
  `2026-07-01T00:33:01+05:30 -> 2026-07-01T08:46:29+05:30`,
  duration `29608s` (`8h13m`), `30773` samples, average HR `64`.
- It did not auto-confirm it as final sleep. It is pending user confirmation:
  `pending_sleep_review_status=pending_user_confirmation`,
  `pending_sleep_review_kind=sleep`,
  `pending_sleep_review_source=sleep_window`.
- The pending policy is honest:
  `strap_hr_review_without_stage_fabrication`. Stages and recovery promotion
  should not be fabricated while strap motion/stage validation is missing.
- The latest already-confirmed sleep record is still the old June 30 nap
  (`09:04 -> 09:25`, `21m`), so UI surfaces must make the new pending sleep
  obvious without pretending it was already accepted.

RR / metric readiness:
- The best saved overnight RR window has strong raw volume but still fails the
  local RR gate because of one large gap:
  `best_saved_rr_raw_beats=23697`, kept `98%`,
  blocker `rr_gap_373.1s_gt_3s`.
- A sub-segment inside that night is locally clean:
  `max_gap_s=2.9`, kept `99%`, blocker
  `none_reference_still_required`.
- Conclusion: useful evidence exists for review and continuity repair, but HRV
  or sleep-stage-style metric promotion must still wait for reference
  validation and/or gap repair.

Code change from this checkpoint:
- Tightened battery charging representation in `AtriaHomeView.CoreLiveState`.
  A charging bolt or `Charging` badge now requires active positive evidence:
  `batteryIsCharging && batteryChargeStatus == .charging &&
  !batteryRecentlyDropping`.
- If `.charging` is stale or contradicted by a recent battery drop, the UI now
  falls back to `Strap state pending` / fresh-evidence wording instead of
  showing a false charging state.
- Added static guardrails so stale/contradictory charging cannot regress back
  into a confident charging badge.

What this checkpoint does not claim:
- It does not prove full sleep auto-confirmation is finished. Current behavior
  is detection plus pending user review.
- It does not prove RR metric promotion is safe for the whole night yet.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Physical Release build/install/run passed with the charging representation
  patch installed, then Atria was relaunched in normal end-user mode:
  `logs/live-device/20260701T092441Z.log`.
- Release live evidence from that run:
  `standard_2a37_frames=33`, `standard_2a37_rr_frames=22`,
  `standard_2a37_rr_values=29`, `last_standard_2a37_hr=80`,
  `last_rr_quality_source=2a37`, `hrv_max_rr_gap_s=2.0`.
- Battery evidence from the exact installed Release run stayed fail-closed:
  widget snapshot reported `battery=61`, `charge=levelOnly`, and live 2A19
  battery reads persisted `61%` instead of showing active charging.

## Wake-up review readability checkpoint - July 1, 2026

This pass continued the current objective: learn from WHOOP, keep Native Liquid
Glass, reduce text, and make detected sleep/workout review feel user-first
instead of developer-first. Current WHOOP references reinforce the same pattern:
auto-detected sleep/activity should become a simple review moment, workout
detection should improve labels while avoiding false positives, and strength
workouts should support exercise-level detail after the user confirms.

Research / audit inputs:
- WHOOP support and current feature notes: activity/sleep auto-detection,
  workout auto-detect/classify improvements, source attribution, and strength
  exercise details.
- Sidecar audit found the most overloaded Atria surfaces are Morning Journal,
  workout review, manual sleep adjustment, trend coverage, and backup/local-save
  status. No source-policy changes were recommended.
- Detection/notification sidecar confirmed pending sleep/workout review is
  reconstructed from saved evidence and only confirmed records persist. That
  is the correct fail-closed shape; the UI can become friendlier without
  promoting unconfirmed data into metrics.

What changed:
- The pending sleep card now leads like a wake-up decision card:
  `Atria found your sleep` / `Atria found a nap`.
- Removed the redundant visible state-header lead from the primary sleep review
  path and inserted the existing visual progress rail immediately after the
  actions: captured -> adjust -> count/save.
- Shortened the explanatory text to: confirm/adjust before recovery uses it.
- Workout review header copy now says `Confirm the time, choose the type, then
  save it` instead of developer-facing `strap-HR window` language.

What did not change:
- No sleep auto-confirmation threshold, nap/sleep classification, recovery
  promotion, notification cadence, workout detector threshold, source policy,
  or persistence changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-wakeup-decision.jpg`.

Remaining high-value work:
- Morning Journal still does too much at once; it should become a compact
  morning stack with one sleep decision and quick tags, not a mixed dashboard.
- Workout review should become more of a receipt: duration, peak HR, zone,
  likely type, and exercise detail only after the type step.
- Trend/backup cards should stop leading with coverage/debug concepts and show
  human state first, with coverage/source metadata demoted.

## Morning Journal action-first checkpoint - July 1, 2026

This pass handled the highest-friction item from the sidecar UI audit: Morning
Journal was mixing sleep review, metric facts, path explanation, quick tags,
and a local-save footer in one dense card. The goal was not to add another
surface; it was to make the existing Native Liquid Glass journal screen easier
to consume.

What changed:
- Sleep confirm/adjust actions now appear before Eff/HRV/Resp fact pills.
- The old footer sentence (`Tags stay on device...` / saved-days text) was
  removed from the card body.
- The visual journal rail was retained but reframed as a compact morning stack:
  Sleep -> Tags -> Impact.
- The journal rail now says local impact learning without another paragraph.
- Quick tag selected state no longer uses a purple accent; it follows the calmer
  cyan journal language already used by the card.

What did not change:
- No behavior-tag persistence, sleep confirmation, journal insight math,
  notification behavior, source policy, or metric promotion changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment journal --atria-ui-fixture
  pending-sleep-review`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-morning-journal-action-first.jpg`.

Remaining observation:
- The visible `Impact Unlock` chip is still a little abstract. A future pass can
  make this more human, e.g. `After 3 days` or `Learning locally`, without adding
  paragraph copy.

## Workout review receipt-first checkpoint - July 1, 2026

This pass handled the next high-friction item from the UI audit: workout review
opened like a process checklist, with capture diagnostics and review choices
before the user saw a simple workout receipt. The new top card keeps the Native
Liquid Glass structure but leads with what a user cares about first.

What changed:
- Workout review title now leads with `Workout found`.
- Header copy is shorter: `Confirm what happened, then Atria learns.`
- Added a receipt board directly in the top card: Time, Peak, Likely type.
- Removed the first-step capture-check and confirm/adjust/reject rails from the
  visible header path. Those diagnostic helpers remain available in code but no
  longer dominate the first screen.
- Time step now says `Confirm time` and uses a simpler local summary:
  Window, Peak, Type.

What did not change:
- No workout detector thresholds, candidate reviewability rules, confirmation
  persistence, exercise catalog, source policy, or metric promotion changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-fixture workout-review-flow`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-receipt-first.jpg`.

Remaining observation:
- The step rail still exposes process language (`1/4`, Now/Next). It is less
  harmful now because the receipt leads, but a future pass can make it even more
  invisible until the user needs navigation context.

## Trends and backup summary-first checkpoint - July 1, 2026

This pass started the Trend/Backup cleanup called out by the audit. These
surfaces were still leading with implementation language (`Local 90-day
coverage`, `State`, `Confirmed`) instead of a user-readable summary.

What changed:
- `AtriaOverviewTrendSection` now leads with `History is ready` or
  `History is building`.
- Trend coverage remains visible as a large number, but coverage/confidence/
  source are demoted into small metadata chips.
- `AtriaOverviewBackupSection` now leads with `Saved on device`.
- Backup confirmed sessions are shown as a simple receipt with Workouts, Sleeps,
  and State chips instead of a paragraph that repeats counts.
- The old coverage-first Trend header and `Backup / On-device safety net`
  header are guarded against returning.

What did not change:
- No trend math, backup persistence, confirmed workout/sleep counts, export
  behavior, source policy, or production launch/deferred-loading policy changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Visual evidence of the Trends graph path and lower loading state:
  `artifacts/visual-checks/simulator/20260701-trends-lower-loading-state.jpg`.
- Follow-up visual proof added a DEBUG-only fixture allowance so the same
  deterministic trend fixture can reveal the trailing saved-insights cards
  without changing Release behavior.
- Visual evidence of the patched Backup card:
  `artifacts/visual-checks/simulator/20260701-trends-backup-summary-first.jpg`.

Follow-up note:
- `AtriaOverviewTrailingSection.showsSavedInsights` mirrors the chart host's
  DEBUG fixture path: production users still need real `snapshotStore`
  diagnostics readiness, while simulator visual checks can see `Saved on
  device`, `Workouts`, `Sleeps`, and `State` in the lower Trends area.

## Morning Journal quick-tag checkpoint - July 1, 2026

This pass applies the same user-first rule to Morning Journal: lead with the
most likely daily tags and hide the rest behind a tiny progressive reveal. The
card should feel like a guided morning checkpoint, not a developer form.

What changed:
- Morning Journal now shows only Sleep, Training, and Caffeine by default.
- Alcohol and Stress sit behind a compact `+2` Liquid Glass action, which
  toggles to `Less` when expanded.
- The selected-tag summary still shows what has already been logged today.
- Static guards now enforce the quick-tag reveal behavior so the full tag list
  does not silently return to the first viewport.

What did not change:
- No journal persistence, tag model, sleep confirmation behavior, correlation
  math, notification behavior, source policy, or health inference changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment journal --atria-ui-fixture
  journal-impact`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-morning-journal-quick-tags.jpg`.

## Trends period-rail checkpoint - July 1, 2026

Current WHOOP references still frame the app around daily action plus drill-down:
Sleep, Recovery, Strain, Journal, Weekly Plan, and trend views live as supporting
detail instead of raw telemetry dashboards. This pass keeps Atria's Trends surface
visual and scannable while preserving week/month/quarter-style summaries.

What changed:
- Replaced the three text-heavy `AtriaTrendRangeLens` tiles with one compact
  period rail: selected range, coverage/readiness, a visual progress line, and
  the latest metric value.
- Kept the existing range dock, period glance board, summary strip, position
  band, dot strip, and chart; this is a readability pass, not a data-model change.
- Added static guards for the rail contract so the old `rangeLensTile` layout
  does not return.

What did not change:
- No trend persistence, rollup semantics, recovery math, chart sampling, metric
  colors, source policy, or notification behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Semantic UI snapshot exposed:
  `Trend period rail. Month, ready, latest Resting HR 60 bpm.`
- First-viewport visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-period-rail.jpg`.
- Scrolled rail visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-period-rail-scrolled.jpg`.

## Notification copy checkpoint - July 1, 2026

Current WHOOP positioning keeps auto-detected sleep/workout moments framed as
daily action: check the window, confirm it, label it, then move on. Atria's
notification gates were already conservative, but the notification text still
read like detector output.

What changed:
- Sleep review notifications now say `Check last night's sleep` or `Check your
  nap`.
- Sleep bodies now lead with `Atria found ...` plus the time window, then ask
  the user to confirm or adjust.
- Workout review notifications now say `Log this workout?` or `Save this
  effort?`.
- Workout bodies now say the window came `from your strap`, then use simple
  review hints like `Looks complete.`, `Adjust if the timing is off.`, or
  `Some minutes are missing.`
- Removed the old notification-only helper wording around `strap-HR signal`,
  `Clean strap capture`, `Review strap gaps`, and `Fragmented strap capture`.

What did not change:
- No notification gating, candidate selection, cooldown, reminder limits,
  dismiss handling, workout detection, sleep detection, persistence, or source
  policy changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Visual regression evidence for the surrounding sleep-review flow:
  `artifacts/visual-checks/simulator/20260701-notification-copy-review-regression.jpg`.

## Workout type guided-picker checkpoint - July 1, 2026

The workout review flow should lead the user through decisions instead of
dumping a taxonomy. WHOOP-style workout review is valuable because the user can
quickly confirm the detected window, choose an activity family, and move on.

What changed:
- `AtriaWorkoutReviewFlow` now keeps the Type step progressive.
- The first Type view shows suggested activity cards plus the currently selected
  type.
- The full activity catalog stays available behind a compact `+N` / `Less`
  reveal.
- If the selected type is not one of the suggestions, it stays visible in the
  collapsed picker so the user's current choice never disappears.
- Static guards now protect `visibleWorkoutTypes`, `hiddenWorkoutTypeCount`, and
  the workout-type reveal control.

What did not change:
- No workout detection, candidate gating, exercise catalog contents, confirmed
  workout persistence, notification logic, source policy, or strap-HR math
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-fixture
  workout-review-flow --atria-workout-review-type-step`.
- Runtime UI snapshot exposed `Show 12 more workout types`.
- First-viewport visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-type-guided-picker.jpg`.
- Reveal-control visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-type-more-reveal.jpg`.

## Workout exercise likely-moves checkpoint - July 1, 2026

After the Type step became guided, the Exercises step still made users read
guide metrics and a path rail before seeing the movements they were most likely
to add. This pass makes the first action the useful action: tap remembered
movements, then search only if needed.

What changed:
- Removed the exercise guide metric row and exercise selection path row from
  the visible Exercises step.
- `exerciseQuickAddStrip` now appears immediately after the step title.
- The strip is labeled `Likely moves` instead of `Quick add`.
- Search is reframed as a fallback with `Search only if needed` and `Skip
  exercises if you are unsure.`
- Static guards now require the likely-moves-first flow and block the old guide
  metric/path helpers from returning.

What did not change:
- No workout detection, exercise catalog contents, suggested-exercise mapping,
  selected-exercise persistence, confirmed workout saving, notification logic,
  source policy, or strap-HR math changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-fixture
  workout-review-flow --atria-workout-review-exercises-step`.
- Runtime UI snapshot exposed `Likely moves` and direct add actions such as
  `Add Barbell bench press`, `Add Cable chest fly`, and `Add Rope pushdown`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-exercises-likely-moves-first.jpg`.

## Workout summary receipt checkpoint - July 1, 2026

The final workout review step should feel like a receipt: one glance at what
will be saved, then one confident save action. The previous receipt worked, but
the visual hierarchy was too even; activity type and duration should dominate.

What changed:
- The Summary step subtitle now says `Final check before this workout joins
  your day.`
- `summaryReceiptLens` now leads with a circular activity mark, large activity
  type, large duration, and `Strap HR` source badge.
- The saved details remain below as compact `Time`, `Type`, and `Moves` tiles.
- The zone strip still appears below the saved details when zone evidence is
  available.
- Static guards now protect the large activity/duration receipt shape.

What did not change:
- No workout detection, candidate gating, exercise selection, confirmed workout
  persistence, notification behavior, source policy, or strap-HR math changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-fixture
  workout-review-flow --atria-workout-review-summary-step`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-summary-save-receipt.jpg`.
- Semantic snapshot was not captured because the simulator shut down after the
  screenshot; static guards still cover the receipt labels/accessibility string.

## Daily focus live-state wording checkpoint - July 1, 2026

The Today daily focus rail is a high-value WHOOP-style surface: four small
signals that should explain the day at a glance. The Live tile was still leaking
developer language by showing raw sample counts when the user only needs to know
whether the strap is live, reconnecting, or blocked by Bluetooth.

What changed:
- Added `liveFocusDetailText` for the daily focus rail.
- The Live focus tile now uses human connection states: `Strap live`, `Strap
  ready`, `Reconnecting`, `Bluetooth off`, `Last seen ...`, or `Waiting`.
- Removed raw `N samples` wording from the daily focus Live detail.
- Static guards now protect the human Live wording and block the old sample
  count detail from that rail.

What did not change:
- No BLE status handling, sample collection, battery parsing, daily focus
  layout, metric calculations, notification behavior, source policy, or
  persistence changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  daily-focus-rail`.
- Runtime UI snapshot exposed `Live Off, Bluetooth off`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-daily-focus-live-human-state.jpg`.

## Journal impact glance-board simplification - July 1, 2026

This pass applies the same "one glance, then detail" rule to Journal impacts.
The previous impact card stacked evidence chips, a balance rail, impact map,
compass, focus row, and bars. That made users inspect several widgets before
understanding which behavior mattered.

What changed:
- Added `AtriaJournalImpactGlanceBoard`.
- The board combines the top behavior, support/watch lanes, impact map, and
  compact logged/signals/focus chips.
- `AtriaJournalImpactStrip` now renders the glance board followed by the
  existing per-tag impact bars.
- Static guards ensure the old stacked `impactEvidenceRail`,
  `AtriaJournalImpactBalanceRail`, compass, and focus row are not rendered in
  the primary impact strip body.

What did not change:
- No journal persistence, tag behavior, behavior-correlation math, source
  policy, cloud/network behavior, or cache behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment journal --atria-ui-fixture
  journal-impact-focus`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-journal-impact-glance-board.jpg`.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Trends-first visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-content-first-clearance.jpg`.
- System-banners-after-content visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-system-banners-after-content.jpg`.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  saved-workout-review`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-checkpoint-simplified.jpg`.

## Trends glance-board simplification - July 1, 2026

This pass continues the "think user, not developer" direction. The Trends tab
already had day/week/month/3-month/6-month ranges and rich period math, but the
top of the screen rendered too many separate explanation cards before the
actual graph. Users should see the period story in one glance, not inspect an
orbit, hero, report, balance map, signal stack, readout card, and action card.

What changed:
- Added `AtriaTrendGlanceBoard`, a compact visual summary for the selected
  period.
- The board combines the period cue, reserve/load lanes, and HRV/RHR/Strain
  mini gauges.
- `AtriaTrendChartCard` now renders this one board when period signal is ready
  instead of the old multi-card period stack.
- Assessment/action cards remain available only for thin or learning states,
  where extra guidance is actually useful.
- Added static guards so the Trends body cannot reintroduce the duplicate
  orbit/hero/report/balance/signal/readout calls.

What did not change:
- No trend aggregation math, daily metric cache, fixture data, source policy,
  graph ranges, or metric calculations changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-glance-board.jpg`.
- Full board visual evidence after one scroll:
  `artifacts/visual-checks/simulator/20260701-trends-glance-board-full.jpg`.

## Bottom glass clearance checkpoint - July 1, 2026

Visual validation of the Trends glance board showed that useful content could
still sit behind the native floating tab bar. That violates the "least effort"
goal because the user has to mentally separate the card from the chrome.

What changed:
- Increased `scrollBottomClearance` to `188` without the live accessory and
  `260` with it.
- Increased the clear bottom `safeAreaInset` to `148` without the live
  accessory and `220` with it.
- Added an `AtriaOverviewTabContent` segment callback so `AtriaHomeView` knows
  whether the user is on Today, Journal, or Trends.
- System banners now lead only on Today when there is no primary review action;
  Journal/Trends lead with their selected content and show system banners after.
- Updated static guards so future UI passes do not shrink the runway and put
  cards behind the Liquid Glass tab chrome again.

What did not change:
- No tab structure, detection logic, graph math, source policy, or persistence
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  saved-workout-review`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-checkpoint-simplified.jpg`.
- Simulator visual checks:
  - `artifacts/visual-checks/simulator/20260630-atria-workout-review-flow-time-elegant.jpg`
  - `artifacts/visual-checks/simulator/20260630-atria-workout-review-flow-type-elegant.jpg`

Still not fully proven:
- This proves the UI/scheduler/export path and the simulator interaction flow.
  The next real workout should validate that a fragmented saved candidate
  appears as the new review card/notification on the physical iPhone after the
  workout window.

## Overnight device checkpoint - July 1, 2026 direct sleep-review bridge

This pass targets the morning trust gap: a real overnight HR-only sleep
candidate should surface for review even when the cached rollup snapshot has
not promoted it yet. It should **not** be silently auto-confirmed.

What changed:
- Added `SessionStore.latestSleepReviewNightForUI(rest:source:)`. It first
  returns the cached `sleepHistorySnapshot.latest`, then falls back directly to
  the aggregate sleep detector.
- The fallback only creates a reviewable `SleepHistorySnapshot.Night` when a
  real aggregate sleep/nap candidate exists and does not overlap already
  confirmed sleep.
- Overview sleep review and sleep-review notifications now use that direct
  bridge, so a 5-6 hour HR-only overnight candidate can appear for user
  confirmation even if the rollup snapshot is stale.
- Sleep auto-confirm remains strict: motion-validated, non-low-confidence
  candidates only.
- Metric detail sheets now include a compact visual range-dot strip above the
  chart, giving a fast day/week/month/quarter pattern read before the larger
  chart.

Physical-device state:
- Built Release for paired physical iPhone
  `3803F5B6-1666-56D3-A71A-62F131F6CE3B`.
- Installed `build/DerivedData/Build/Products/Release-iphoneos/Atria.app`.
- Launched `com.adidshaft.atria` with:
  `--atria-verify-sleep --atria-schedule-sleep-validation
  --atria-schedule-notifications --atria-log-trends`.
- `devicectl device info processes` showed both the main Atria app process and
  `AtriaWidget.appex` running.

Morning validation to perform:
- Pull app container/logs after Aman wakes up.
- Confirm `ATRIADBG sleep_review_candidate` appears if aggregate sleep exists
  before snapshot promotion.
- Confirm Overview shows the overnight sleep review card, not just a short nap.
- Confirm the sleep-review notification uses the same candidate and is not
  suppressed by dismissed/already-notified defaults.
- Confirm recovery remains review-before-recovery for low-confidence HR-only
  sleep and only updates after user confirmation or stricter validation.

In-night checkpoint at **July 1, 2026 00:21 IST**:
- `devicectl` still showed the physical iPhone reachable and Atria running.
- Targeted app-container pull succeeded for:
  `artifacts/live-device/20260701-002150-overnight-check/Documents/atria-active-session.segments/segment-00000000.json`,
  `artifacts/live-device/20260701-002150-overnight-check/Documents/atria-gate-status.txt`, and
  `artifacts/live-device/20260701-002150-overnight-check/Documents/atria-backups/atria-sessions-20260630T152530Z-auto-session-add.json`.
- Active segment had fresh live strap HR (`74 bpm`) and battery `75%`.
- Gate status showed BLE connected, live battery `notCharging`, `active_collection_status=active`, and `current_collection_ready=1`.
- Gate status also showed the current active journal had just rolled over from a `Long wear` segment, so morning validation must verify stitched overnight fragments, not a single uninterrupted file.
- Full `Documents` copy failed with a CoreDevice socket timeout because the archive is large; targeted small-file pulls worked and are safer mid-sleep.
- Added follow-up wording guards so low-confidence review-only candidates display `HR-only` in the card/notification instead of sounding fully validated. This wording change was built/tested locally but was **not reinstalled mid-sleep** to avoid interrupting the running physical-device capture.

## Home live HR zone checkpoint - July 1, 2026

The home live heart-rate surface now answers the fast glance question: "which
zone am I in right now?"

What changed:
- Added `Metrics.HeartRateZone` and `Metrics.heartRateZone(bpm:rest:max:)`.
  The buckets use personalized HR reserve from the same rest/max inputs used
  elsewhere in Atria's strain/workout math: Zone 0 <30%, Zone 1 30-50%, Zone 2
  50-70%, Zone 3 70-80%, Zone 4 80-90%, Zone 5 >=90%.
- `AtriaHomeModel.HeroPulseState` now carries the current zone next to the
  strap-derived live bpm. It is computed from `LiveSessionDerived.rest` and
  `LiveSessionDerived.maxHR`, not from phone motion or any iPhone step source.
- `AtriaConnectedPulseStatusCard` now renders a compact six-segment
  `AtriaHeartRateZoneRail` under the live bpm: active segment highlighted,
  `Zone N` plus a short effort name, and restrained zone color inside the
  existing native glass card.
- Accessibility now announces the live bpm, strap display name, active zone,
  and effort label.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed
  with 92 tests.
- `git diff --check` passed.
- `xcodebuild -quiet -project Atria/Atria.xcodeproj -scheme Atria
  -configuration Release -destination 'generic/platform=iOS'
  -derivedDataPath build/DerivedData build` passed.
- The new build was **not installed on the physical iPhone mid-sleep**, so the
  overnight strap capture remains undisturbed. Install/visual verify after the
  morning sleep validation pull.

Follow-up pass:
- The same personalized live zone now reaches the always-visible live accessory
  on non-Overview tabs. It shows a compact `Z#` pill beside the heart and strap
  battery, so the user can glance at zone without opening a workout screen.
- Added a DEBUG-only `--atria-ui-fixture live-zone` screenshot fixture. It holds
  a connected strap state (`142 bpm`, `72%`, `Strap not charging`) long enough
  for simulator screenshots, without changing Release behavior or touching the
  physical iPhone.
- Visual evidence captured on the iOS Simulator:
  `artifacts/simulator/live-zone-overview.png` shows the hero live HR rail with
  `Zone 2 Endurance`; `artifacts/simulator/live-zone-vitals.png` shows the
  bottom accessory `Z2` pill with `Strap not charging`.
- Validation after this follow-up:
  `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks`,
  `git diff --check`, Debug simulator build, simulator install/launch/screenshot,
  and Release generic iOS build all passed.

## In-night protected sleep-capture checkpoint - July 1, 2026 00:50 IST

Physical-device pull:
- Non-disruptive pull ran against physical iPhone
  `3803F5B6-1666-56D3-A71A-62F131F6CE3B` into
  `artifacts/live-device/20260701-005050-in-night-check`.
- Atria and the widget process were running.
- Official WHOOP app/widget process was not listed.
- Battery evidence was live and correct: `battery_level=74`,
  `battery_charge_status=notCharging`, `battery_is_charging=0`.
- Active journal was fresh: `active_journal_label=Long wear`,
  `active_journal_samples=1097`, `active_journal_rr_values=707`,
  `active_journal_updated=2026-07-01T00:51:01.938418+05:30`,
  `active_journal_freshness=fresh`.
- This is still an in-night checkpoint, not morning validation. It is too early
  to prove the final overnight sleep review card.

UX change from the evidence:
- When range-loss backfill is pending but Atria is connected with live samples,
  the Today sleep card now says `Sleep capture protected` instead of
  `Sleep sync needed`.
- The visual state becomes `Live / Protected`, `Sleep / Capturing`,
  `Review / Morning`, which is calmer for overnight wear and matches the real
  state better: do not interrupt live capture just to sync a gap.
- Added DEBUG fixture support for `--atria-ui-fixture live-zone
  sleep-capture-protected`, using low overnight-like HR/strain so the workout
  prompt does not crowd the sleep capture card during visual checks.
- Visual evidence:
  `artifacts/simulator/sleep-capture-protected-overview.png` shows the protected
  sleep capture card under the live HR Zone 0 rail.

## Workout review zone-evidence checkpoint - July 1, 2026

This pass improves the user confirmation step after auto-detected effort.
Instead of asking the user to interpret only peak/average HR text, the workout
prompt and guided review sheet now show personalized HR-zone evidence.

What changed:
- `AtriaWorkoutDetectionPrompt` now carries `restingHeartRate` and
  `maxHeartRate`, then exposes `heartRateZone` through the same HR-reserve zone
  model used by the live home HR card.
- `AtriaWorkoutDetectionBanner` shows a compact six-segment
  `AtriaWorkoutZoneEvidenceStrip` beneath the strap effort rail.
- `AtriaWorkoutReviewFlow` carries the same evidence into the guided sheet:
  the header chips include `Z#`, and the six-segment rail appears before the
  time/type/exercise steps.
- This keeps the confirmation flow visual and fast: bpm, zone, duration, then
  guided edits, instead of more diagnostic copy.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.

## Workout review exercise quick-add checkpoint - July 1, 2026

This pass makes the Exercises step feel more guided for strength-style sessions.
The user sees the most likely movements as first-class quick-add cards before
the full catalog, rather than needing to scan the whole exercise list.

What changed:
- Replaced the generic `Suggested from signal` chip section with
  `exerciseQuickAddStrip`.
- The quick-add strip shows suggested movements as large tappable cards with
  add/check icons and a `selected / suggested` count.
- Added `selectedSuggestedExerciseCount` so the strip communicates progress.
- Added `toggleExercise(_:)` and reused it from both quick-add cards and catalog
  chips, keeping add/remove behavior consistent.

What did not change:
- No workout detection thresholds, activity type selection, exercise catalog
  contents, persistence, HealthKit export, strap-source rules, or notification
  behavior changed.
- The full catalog still appears below quick-add, and search still filters the
  catalog.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed with
  `--atria-ui-fixture workout-review-flow --atria-workout-review-exercises-step`.
- Runtime UI snapshot showed `Quick add` and `0/9`.
- Visual evidence:
  `artifacts/simulator/workout-review-exercise-quick-add-visible-20260701-074752.jpg`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

Research source direction:
- WHOOP-style activity review emphasizes confirming/editing detected activity
  and, for strength-style sessions, logging movements as part of a guided flow.

## Workout review suggested-type runway checkpoint - July 1, 2026

This pass makes the workout confirmation flow lead the user instead of asking
them to scan every activity type equally.

What changed:
- `AtriaWorkoutDetectionPrompt` now exposes up to three
  `suggestedActivityTypes` derived from the strap-HR signal suggestions.
- `AtriaWorkoutActivityType` has a small `init?(suggestion:)` mapper so
  signal labels like `Strength`, `Cardio`, `Mixed`, `Walk`, and `Mobility`
  resolve to real review-flow activity types.
- The Type step now starts with a Native Liquid Glass suggested runway:
  `Strength`, `Cardio`, and `Functional` in the debug fixture.
- Both the runway and the full type grid use `applyWorkoutType(_:)`, so subtype
  defaults and exercise-step clearing stay consistent.

What did not change:
- No workout detection thresholds, saved candidate selection, strap-source
  rules, exercise persistence, notification behavior, or HealthKit export
  changed.
- The full activity catalog remains available below the suggested runway.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed with
  `--atria-ui-fixture workout-review-flow --atria-workout-review-type-step`.
- Runtime UI snapshot showed tappable suggested activities:
  `Strength`, `Cardio`, and `Functional`, plus `Selected type Strength`.
- Visual evidence:
  `artifacts/simulator/workout-review-type-suggested-runway-20260701-074119.jpg`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Trends balance map checkpoint - July 1, 2026

This pass makes the Trends tab more WHOOP-like without adding more prose: the
selected range now gets a compact visual balance map that places recovery
reserve against load pressure, using the existing HRV/RHR/Strain period
readout.

What changed:
- `AtriaTrendChartCard` now shows `AtriaTrendPeriodBalanceMap` after the period
  hero when the selected range has enough signal.
- `AtriaTrendPeriodReadout` derives `recoveryReserve`, `loadPressure`, and a
  concise `balanceCue` from the current-vs-prior HRV/RHR/Strain deltas.
- `AtriaTrendPeriodDelta` now exposes `directionScore(positiveDeltaIsGood:)`
  so the map can interpret HRV up / RHR down as recovery-positive without
  creating a new score model.
- The map stays inside existing Native Liquid Glass inset-card language and
  uses visual quadrants (`Ready`, `Push`, `Recover`, `Protect`) instead of a
  longer explanation block.

What did not change:
- No metric computation, trend caching, workout/sleep detection, strap-source
  rules, HealthKit export, or notification behavior changed.
- The card is a visual readout of already-prepared trend data, not a new
  recovery grade.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed with
  `--atria-ui-screen overview --atria-ui-overview-segment trends
  --atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot exposed the accessibility summary:
  `Balance map. Recovery reserve 74 percent. Load pressure 53 percent. Cue Ready.`
- Visual evidence:
  `artifacts/simulator/trends-balance-map-final-20260701-073425.jpg`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

Research source direction:
- WHOOP Trends support/app direction: weekly/monthly comparisons across Recovery,
  Sleep, Strain, HRV/RHR, and behavioral context.
- WHOOP strain/recovery direction: load should be interpreted against recovery,
  not as an isolated number.

## Workout false-positive visible-hold checkpoint - July 1, 2026

This pass reduces noisy maybe-workout UX. Atria can still keep internal
workout-hold evidence and debug fixtures, but real users should not see a
visible "possible workout" hold card unless there is an actionable review card
or an active live-detection prompt.

What changed:
- `AtriaHomeView` now renders `AtriaWorkoutReviewHoldBanner` only through
  `workoutReviewHoldStateForDisplay`.
- In normal app state, `workoutReviewHoldStateForDisplay` returns `nil`, so
  `waitingForSettle` / `possibleSignal` stay logged/internal instead of
  surfacing as false-positive product UI.
- Debug fixtures still render the hold card for QA via
  `--atria-ui-fixture workout-review-hold-possible` or
  `--atria-ui-fixture workout-review-hold-settle`.

What did not change:
- No strap-source rules, workout thresholds, saved candidate selection,
  notification push-worthiness, exercise catalog, persistence, or HealthKit
  export behavior changed.
- Actionable saved workout-review cards and live workout-detection prompts are
  still allowed to appear.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed with
  `--atria-ui-screen overview --atria-ui-fixture workout-review-hold-possible`.
- Visual evidence:
  `artifacts/simulator/workout-hold-debug-only-20260701-072641.jpg`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Live workout coach cue checkpoint - July 1, 2026

This pass makes the live workout screen more glanceable while preserving the
existing Native Liquid Glass workout HUD. The screen now surfaces a single
movement cue directly under the large heart-rate readout, so the user can see
whether to build, hold, or ease before reading the detailed zone/target cards.

What changed:
- Added a compact `workoutCoachCueCard` to the live workout HUD with a
  build/hold/ease title, cue icon, current HR zone, and a short visual rail.
- Reused the existing strap HR zone and strain target calculations; no new
  source, phone motion, HealthKit, or detector behavior was introduced.
- Tightened the live workout vertical spacing so the cue, source, zone rail,
  focus card, target card, and `End workout` action fit cleanly in the first
  simulator viewport.

What did not change:
- No workout auto-detection thresholds, sample ingestion, storage, confirmation
  flow, HealthKit export, notification behavior, or strap-source boundary
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build and launch passed on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-show-workout live-workout-target-hold`.
- Visual evidence:
  `artifacts/simulator/live-workout-coach-cue-compact-20260701-070620.jpg`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Trends period report checkpoint - July 1, 2026

This pass makes the Trends card feel more like a user-facing period report and
less like diagnostic output. The direction comes from current WHOOP-facing app
positioning around Sleep, Strain, Recovery, Stress, weekly/monthly planning, and
trend context: lead with the period story, then let deeper evidence sit below.

What changed:
- Added `AtriaTrendPeriodHeroCard` above the detailed trend stack.
- The card summarizes the selected period with a short cue such as `Recover`,
  `Protect`, `Ready`, or `Steady`.
- HRV, resting HR, and strain are shown as compact visual gauges with current
  values and directional arrows.
- The implementation reuses existing prepared period data and keeps trend
  computation off SwiftUI render paths.

What did not change:
- No trend calculations, saved-session filtering, workout/sleep detection,
  storage, HealthKit export, or strap-source boundary changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build and launch passed on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-screen overview --atria-ui-overview-segment trends
  --atria-ui-fixture trend-prior-comparison`.
- Visual evidence:
  `artifacts/simulator/trends-period-report-20260701-071250.jpg`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Workout review decision lens checkpoint - July 1, 2026

This pass makes the first workout review screen clearer at the exact moment a
user has to decide what to do with an auto-detected strap-HR window.

What changed:
- Added a compact `reviewDecisionLens` to the workout review header.
- The lens shows the three user actions as visual tiles: confirm if it looks
  right, adjust the time window, or reject if it was not a workout.
- The decision lens sits above the existing guided steps, so the flow remains
  window -> type -> exercises -> save.

What did not change:
- No workout detection threshold, review prompt gate, sample source, storage,
  HealthKit export, or exercise catalog behavior changed.
- Detection remains strap-HR based; no phone motion or HealthKit source was
  introduced.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build and launch passed on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-review-flow`.
- Visual evidence:
  `artifacts/simulator/workout-review-decision-lens-20260701-071620.jpg`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Sleep review notification copy checkpoint - July 1, 2026

This pass makes sleep-review notifications match the morning review flow: a
decision prompt, not a classifier verdict.

What changed:
- Sleep review notification titles are now **Review detected sleep** or
  **Review detected nap**.
- The body now shows duration, time window, and the user action:
  confirm, adjust, or keep a nap separate.
- Removed classifier-style body phrasing like `Full night HR-only main sleep`
  and `Affects recovery`; recovery impact remains explained inside the app.

What did not change:
- No sleep candidate gate, nap-vs-sleep classification logic, notification
  cadence, dismissal memory, storage, recovery math, or strap-source boundary
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Sleep review card compact decision checkpoint - July 1, 2026

This pass aligns the in-app sleep review card with the new notification wording:
review detected sleep/nap, then confirm, adjust, or dismiss.

What changed:
- `AtriaSleepReviewCard` title now says **Review detected sleep** or
  **Review detected nap**.
- The card keeps the visual window strip and classification lens, but removes
  the extra impact paragraph strip that repeated recovery/nap explanations.
- The classification lens now says **Decision** instead of **Impact**, matching
  the user action: main sleep affects recovery; nap stays separate.

What did not change:
- No sleep/nap detection thresholds, confirmation behavior, recovery math,
  notification cadence, storage, or strap-source rules changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Debug app installed/launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`.
- Visual evidence:
  `artifacts/simulator/sleep-review-card-compact.png`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug simulator build/install/launch/screenshot passed.
- Visual evidence: `artifacts/simulator/workout-review-zone-flow.png`.
- Release generic iOS build passed.

## Trends window-pattern checkpoint - July 1, 2026

This pass improves the Trends tab scanability without adding more explanation
copy.

What changed:
- `AtriaTrendChartCard` now renders `AtriaTrendSessionDotStrip` for the selected
  metric/range when at least three prepared samples exist.
- The strip uses the already-prepared range samples, caps itself to the latest
  28 saved sessions, and renders compact vertical capsules. This gives a fast
  visual read of the selected week/month/quarter before the larger chart.
- The visual uses the selected metric tint and avoids adding another grading
  system.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch/screenshot passed.
- Visual evidence: `artifacts/simulator/trends-window-pattern.png`.
- Release generic iOS build passed.

## Protected-capture notification checkpoint - July 1, 2026

This pass aligns notifications with the protected overnight capture state.

What changed:
- Workout-review notifications now defer while Atria is connected, has live
  samples, and range-loss backfill is pending. This matches the Today card state:
  live capture is protected, so do not wake/nudge the user about an effort
  candidate that might be a sleep-capture fragment.
- Sleep-review notifications are intentionally still allowed when a real
  unconfirmed sleep/nap candidate exists, so the morning review can still
  surface.
- Skip reason: `live_capture_protected_range_loss_backfill`.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Release generic iOS build passed.

## Guided workout-label checkpoint - July 1, 2026

This pass tightens the post-detection workout review flow so it behaves more
like a guided confirmation loop instead of a generic form.

What changed:
- `AtriaWorkoutDetectionPrompt` now infers a starting activity type from the
  strap-HR signal (`Walking`, `Cardio`, `Mobility`, or `Strength`) so the review
  sheet opens on the most likely family instead of always defaulting to
  strength.
- `AtriaWorkoutReviewFlow` initializes subtype defaults from that activity
  family, keeps the step-by-step Time -> Type -> Exercises -> Save journey, and
  adds a `Suggested from signal` exercise row before the full searchable
  catalogue.
- The exercise catalogue is broader: added functional, bodyweight, cardio, and
  mobility movements plus more machine/free-weight variants. This gives users a
  useful first-pass list for strength, HIIT, walk/cardio, and mobility sessions
  without dumping every decision onto one screen.
- The confirmed workout persistence path remains strap-HR based. The new labels,
  subtype, and exercises are saved as user confirmation metadata only; they do
  not loosen the automatic workout gate.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch/screenshot passed.
- Visual evidence:
  `artifacts/simulator/guided-workout-label-flow.png` and
  `artifacts/simulator/guided-workout-exercises-step.png`.
- Release generic iOS build passed.

## Trends range-rhythm checkpoint - July 1, 2026

This pass makes the Trends graph easier to scan across day/week/month-style
windows.

What changed:
- `AtriaTrendChartCard` now prepares lightweight coverage counts for every
  range (`D`, `W`, `M`, `Q`, `6M`) for the selected metric.
- Added `AtriaTrendRangeRhythmStrip`, a compact tappable row beneath the metric
  selectors. Each range shows a small capsule and saved-point count, so users
  can see which windows have enough data before switching.
- The strip changes the same `range` state as the native segmented picker and
  uses the selected metric tint. It is visual context, not another readiness
  grade.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch/screenshot passed.
- Visual evidence: `artifacts/simulator/trends-range-rhythm-strip.png`.
- Release generic iOS build passed.

## Sleep review window-strip checkpoint - July 1, 2026

This pass improves the morning sleep/nap confirmation moment.

What changed:
- `AtriaSleepReviewCard` now shows a compact `AtriaSleepReviewWindowStrip`
  between the start/end/signal pills and the recovery impact strip.
- The strip makes the detected window easier to understand at a glance:
  `Main sleep` vs `Nap`, `Full night` / `Partial night` / `Fragment`, and
  whether the confirmation affects `Recovery` or stays `Separate`.
- The duration rail is visual-only context; it does not auto-confirm sleep and
  it does not change the nap-vs-main-sleep detection rules.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch/screenshot passed.
- Visual evidence: `artifacts/simulator/sleep-review-window-strip.png`.
- Release generic iOS build passed.

## Review notification trust-copy checkpoint - July 1, 2026

This pass improves auto-detection notification clarity without changing the
detection gates.

What changed:
- Sleep review notifications now mirror the in-app review semantics:
  `Review main sleep` / `Review nap`, `Full night` / `Partial night` /
  `Sleep fragment`, and whether the review affects `Recovery` or stays
  `Separate`.
- Workout review notifications now distinguish `Review workout` from
  `Review effort`, include strap-HR signal confidence language, and keep peak HR
  plus the detected window in the body.
- Existing duplicate suppression, locally dismissed candidate checks, and
  protected live-capture suppression remain unchanged.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Release generic iOS build passed.

## Today daily-focus rail checkpoint - July 1, 2026

This pass makes the Today widget grid easier to scan before the user reads any
individual card.

What changed:
- Added `AtriaDailyFocusRail` above the existing Today widgets.
- The rail summarizes four high-frequency decisions: `Recovery`, `Strain`,
  `Sleep`, and `Live`.
- Each item reuses the existing value/detail/tint/progress from the underlying
  cards. It does not add new readiness grades or colors.
- Added a DEBUG-only `--atria-ui-fixture daily-focus-rail` path that hides the
  pre-grid Today cards for screenshot verification only; Release behavior is
  unchanged.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch/screenshot passed.
- Visual evidence: `artifacts/simulator/today-daily-focus-rail.png`.
- Release generic iOS build passed.

## Recovery contributor balance checkpoint - July 1, 2026

This pass makes Recovery detail easier to understand visually.

What changed:
- `AtriaRecoveryContributorMap` now shows a compact `Signal balance` strip above
  the detailed contributor rows.
- The strip summarizes supportive vs pressured weighted contributor evidence,
  then keeps the existing HRV/RHR/Sleep/Respiration rows for detail.
- This is explanatory context only: no new Recovery scoring, no new color
  language, and no changes to the underlying Recovery calculation.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch/screenshot passed.
- Visual evidence: `artifacts/simulator/recovery-contributor-balance.png`.
- Release generic iOS build passed.

## Journal impact compass checkpoint - July 1, 2026

This pass makes behavior insights easier to scan without recomputing expensive
rollups in SwiftUI.

What changed:
- Added `AtriaJournalImpactCompass` inside the Journal `Impacts` card.
- The compass summarizes the strongest supportive tag and strongest pressure
  tag, then shows a compact evidence rail for the top local behavior signals.
- The existing top-signal card and signed impact bars remain below it for
  detail.
- The view still reads cached `behaviorCorrelationSummariesCache`; it does not
  trigger workout/sleep clustering or behavior correlation recomputation from
  the body.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch/screenshot passed.
- Visual evidence: `artifacts/simulator/journal-impact-compass.png`.
- Release generic iOS build passed.

## Workout false-positive reduction checkpoint - July 1, 2026

This pass makes workout auto-detection less chatty and closer to a real
activity-review product.

What changed:
- The live workout prompt now waits for a stronger signal: about 15 minutes of
  samples, visible strain >= 8.0, and +35 bpm over rest.
- Saved workout review candidates no longer surface merely because stream
  coverage reached 20%.
- User-facing near-miss / strength-like candidates now require at least 15
  minutes of observed strap HR and 60% stream coverage.
- The saved workout review banner now shows a visual detected-window rail,
  peak-vs-average HR evidence, and peak HR zone context before Confirm / Not
  this.
- Added a DEBUG-only `--atria-ui-fixture saved-workout-review` path for visual
  verification.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch/screenshot passed.
- Runtime UI snapshot after scroll showed `Effort ready to review`, `Detected
  window`, `Peak`, `Average`, `Zone 3`, `Confirm workout`, and `Not this`.
- Visual evidence: `artifacts/simulator/saved-workout-review-evidence.png` and
  `artifacts/simulator/saved-workout-review-evidence-scrolled.jpg`.
- Release generic iOS build passed.

## Workout review settle-gate checkpoint - July 1, 2026

This pass prevents workout review from surfacing while effort may still be in
progress.

What changed:
- `latestWorkoutReviewCandidate` now requires the best candidate to be ended
  for at least 10 minutes before returning it to UI or notifications.
- The Overview saved-review banner also stays hidden while the strap is
  connected and live HR is still more than 20 bpm above rest.
- Weak workout-like evidence remains diagnostic/training evidence; it is not
  allowed to become a user-facing review prompt during the settle window.
- The saved workout review fixture still renders the review surface for visual
  verification.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed.
- Runtime UI snapshot after scroll still showed `Effort ready to review`,
  `Detected window`, `Peak`, `Average`, `Zone 3`, `Confirm workout`, and
  `Not this`.
- Visual evidence: `artifacts/simulator/saved-workout-review-settle-gate.jpg`.
- Release generic iOS build passed.

## History activity-rhythm checkpoint - July 1, 2026

This pass makes the Data > History view more visual and easier to scan.

What changed:
- Added `HistoryActivityRhythmCard` above Daily rollups.
- The card turns the recent 14-day rollup cache into a compact bar rhythm:
  strain height, workout/review/sleep/rest markers, and three small count pills.
- It uses existing `HistorySnapshot.rollups`; History still does not recompute
  detections, trends, daily rollups, TRIMP, or sessions from the SwiftUI body.
- Added a DEBUG-only `--atria-ui-fixture history-activity-rhythm` path for
  visual verification.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed.
- Runtime UI snapshot in History showed activity rhythm counts and daily rollups
  from the fixture.
- Visual evidence: `artifacts/simulator/history-activity-rhythm.jpg`.
- Release generic iOS build passed.

## Metric detail range-lens checkpoint - July 1, 2026

This pass makes metric detail sheets easier to scan before reading the chart.

What changed:
- Added `AtriaDetailRangeLensCard` below the Day/Week/Month/Quarter/6M picker.
- The card shows latest, average, selected-window movement, and current-vs-prior
  comparison using compact rails.
- Recovery, HRV, RHR, Sleep, and Strain detail sheets all reuse the same
  prepared history summaries; no SwiftUI body recomputes daily history.
- Extended the DEBUG `recovery-detail` fixture with representative
  `SavedDailyMetric` values so the card can be visually verified.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed.
- Runtime UI snapshot showed `Range lens`, `Month`, `Latest`, `Avg`, `Move`,
  and `Vs prior` in the recovery detail sheet.
- Visual evidence: `artifacts/simulator/detail-range-lens.jpg`.
- Release generic iOS build passed.

## Live workout zone-focus checkpoint - July 1, 2026

This pass improves the in-workout HUD so zone context is visible at a glance.

What changed:
- Added `zoneFocusCard` to `AtriaLiveWorkoutView` below the zone rail.
- The card shows current zone, max-HR-based BPM band, live sample count, and
  whether workout evidence is still building or steady.
- It uses the existing live stores and max-HR zone model; no detector, workout
  save, calorie, or strain pipeline changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed.
- Runtime UI snapshot showed `Zone focus`, `Aerobic`, `Band`, `Samples`,
  `Evidence`, and `End workout` in the full-screen workout HUD.
- Visual evidence: `artifacts/simulator/live-workout-zone-focus.jpg`.
- Release generic iOS build passed.

## Workout review-worthy gate and sleep lens checkpoint - July 1, 2026

This pass separates diagnostic workout-like evidence from user-facing workout
review prompts. Atria should still learn from weak HR-only activity signals, but
it should not keep asking the user about ordinary elevated-HR moments.

What changed:
- Added a stricter `reviewWorthyCandidate` gate on saved workout evidence.
- User-facing aggregate workout candidates now need a cleaner signal before
  appearing in detected activities, daily rollups, review prompts, or best
  candidate confirmation.
- The gate keeps ready workouts valid, but weak near-miss / strength-like
  evidence must now have at least 25 minutes observed, 75% stream coverage,
  +35 bpm over rest, and sustained elevated or borderline HR before surfacing.
- Added a DEBUG-only `sleep-history-context-lens` fixture for Vitals.
- Added `AtriaSleepContextLens` above the Sleep history metric grid, showing
  duration progress, Type, Recovery impact, and Routine at a glance.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed.
- Runtime UI snapshot in Vitals showed `Sleep lens`, `Type`, `Recovery`,
  `Routine`, `Review sleep`, and the seeded 10-night average.
- Visual evidence: `artifacts/simulator/sleep-history-context-lens.jpg`.
- Release generic iOS build passed.

## Overview Trends visual proof checkpoint - July 1, 2026

This pass closed the earlier evidence gap around the Overview `Trends` segment.
The trend UI was already implemented and statically guarded, but it now has a
representative simulator proof using the existing `trend-prior-comparison`
fixture.

What was verified:
- `--atria-ui-overview-segment trends` opens the real Overview Trends segment.
- The DEBUG `trend-prior-comparison` fixture seeds 70 deterministic trend
  points without mutating the store.
- The card shows the WHOOP-like readout stack: range rhythm, metric selector,
  current-vs-prior period readout, action readout, window pattern, and chart.
- Runtime UI showed `Trends`, `Last 30 days · 31 sessions`,
  `Strain-heavy month`, `HRV 55 ms, +6 ms`, `RHR 60 bpm, -2 bpm`,
  `Strain 10.2, +1.1`, `RHR steady`, `Window pattern`, and `28 saved`.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed.
- Visual evidence:
  `artifacts/simulator/overview-trends-prior-comparison.jpg` and
  `artifacts/simulator/overview-trends-window-pattern.jpg`.
- Release generic iOS build passed.

## Workout notification trust-copy checkpoint - July 1, 2026

This pass tightened the language around automatic workout review notifications.
The detector gate was already strict; the notification copy now matches that
trust model instead of sounding like Atria is certain every elevated-HR window
was a workout.

What changed:
- Workout review notifications continue to call
  `latestWorkoutReviewCandidate(... source: "notification")`, so they inherit
  the stricter review-worthy gate.
- Low-confidence review candidates now title as **Possible workout?** instead
  of **Review effort**.
- The body now says `strap-HR possible workout pattern` / `likely workout
  pattern` / `workout-like pattern`, includes the time window and peak HR, and
  asks the user to label, adjust, or dismiss.
- Confirmed-ready workout candidates still use **Review workout** and the
  direct confirm/adjust wording.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Source verification showed `source: "notification")`, `Possible workout?`,
  `Open Atria to label, adjust, or dismiss it.`, and the new workout-pattern
  signal strings in `LocalNotificationScheduler`.
- Debug simulator build passed.
- Release generic iOS build passed.

## Home live HR-zone lens checkpoint - July 1, 2026

This pass makes the live heart-rate zone visible on the home hero without
requiring workout mode. The existing color rail stays, but the hero now has a
larger zone lens for instant zone recognition.

What changed:
- Added `AtriaHeartRateZoneLens` below the existing live HR zone rail.
- The lens shows `HR zone`, the short zone label, zone name, reserve percent,
  and a compact cue (`Recover`, `Easy`, `Build`, `Tempo`, `Hard`, `Max`).
- It reuses `Metrics.HeartRateZone` and `reserveFraction`; no detection,
  workout, strain, or calorie pipeline changed.
- The surface stays inside the existing Liquid Glass card language via
  `atriaInsetCard`/rounded glass-style inset treatment, with no extra text wall.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed with the existing `live-zone`
  fixture.
- Runtime UI snapshot showed `HR zone`, `Z2`, `Endurance`, `Reserve`, `64%`,
  `Cue`, and `Build` on the home hero.
- Visual evidence: `artifacts/simulator/home-live-hr-zone-lens.jpg`.
- Release generic iOS build passed.

## Saved workout review path checkpoint - July 1, 2026

This pass fixes the first trust moment after automatic workout detection. The
saved review card now appears before the long Overview stack once a candidate
passes the stricter review-worthy gate, and its primary action describes the
actual guided flow.

What changed:
- Moved `AtriaSavedWorkoutReviewBanner` above `AtriaOverviewTabContent` so a
  reviewable candidate is not buried below every Today card.
- Changed the primary action from **Confirm workout** to **Review & label**,
  because it opens the guided review sheet rather than instantly confirming.
- Added a compact three-step path strip: `Window`, `Type`, `Exercises`.
- Kept the existing detected-window rail, peak/average HR, signal, and zone
  evidence intact.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed with the `saved-workout-review`
  fixture and `--atria-ui-overview-segment today`.
- Runtime UI snapshot showed `Effort ready to review`, `Detected window`,
  `Zone 3`, `Peak`, `Average`, `Signal`, `Review & label`, `Not this`,
  `Window`, `Type`, and `Exercises` before the main Today stack.
- Visual evidence: `artifacts/simulator/saved-workout-review-path.jpg`.
- Release generic iOS build passed.

## Workout review type-step lens checkpoint - July 1, 2026

This pass makes the guided workout confirmation sheet less dump-like on the
activity label step. The user now gets a compact selected-state lens before
the full activity grid, so the flow confirms what is selected and whether an
exercise step is coming next.

What changed:
- Added `selectedTypeLens` to the `What type was it?` step.
- The lens shows the selected activity icon, `Selected type`, the label
  (`Strength`, `Cardio`, etc.), the selected style or next-step hint, and a
  compact `3 steps`/`2 steps` affordance.
- Added `--atria-workout-review-type-step` debug launch support so the Type
  step can be visually checked directly.
- Kept the footer clean: the only bottom actions remain `Back` and `Continue`.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- Debug simulator build passed.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-review-flow --atria-workout-review-type-step`.
- Runtime UI snapshot showed `Workout review step Type`, `What type was it?`,
  `Selected type Strength. Exercises next.`, `3 steps`, `Exercises`, `Back`,
  and `Continue`.
- Visual evidence: `artifacts/simulator/workout-review-type-lens.jpg`.

## Workout review exercise-step lens checkpoint - July 1, 2026

This pass makes the exercise selection step feel more guided without turning it
into a text-heavy form. Users now see a compact visual scope before search,
signal suggestions, and the full catalog.

What changed:
- Added `exerciseGuideLens` above the exercise search field.
- The lens shows three glanceable tiles: `Selected`, `Signal`, and `Catalog`.
- The `Selected` tile updates from `0 / Optional` to the selected count; the
  `Signal` tile reflects prompt-driven suggestions; the `Catalog` tile shows
  the number of exercise groups available.
- Detection, strap source rules, and save semantics are unchanged.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- Debug simulator build passed.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-review-flow --atria-workout-review-exercises-step`.
- Runtime UI snapshot showed `Workout review step Exercises`, `Add exercises`,
  `Exercise guide. 0 selected. 9 suggested. 14 catalog groups.`, `Selected`,
  `Signal`, `Catalog`, `Suggested from signal`, `Back`, and `Continue`.
- Visual evidence: `artifacts/simulator/workout-review-exercise-lens.jpg`.

## Overview Trends range-lens checkpoint - July 1, 2026

This pass adds a more glanceable, WHOOP-style fixed-period readout to the
Overview `Trends` card without adding another graph tab or text block. The
selected range now gets a compact lens before the deeper readouts.

What changed:
- Added `AtriaTrendRangeLens` inside `AtriaTrendChartCard`.
- The lens shows `Range`, saved session count, and latest value for the
  currently selected metric.
- It reuses the existing prepared trend summary and selected range state; no
  new storage, detection, or analytics pipeline was added.
- The lens sits after the range rhythm strip and before period/action readouts,
  so users can immediately understand the selected window before reading the
  rest of the card.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- Debug simulator build passed.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot showed `Trend range lens. Month, 31 saved sessions,
  latest Resting HR 60 bpm.`, plus `Range`, `Saved`, `Resting HR`, `M`, `31`,
  `60 bpm`, and `latest`.
- Visual evidence: `artifacts/simulator/overview-trends-range-lens.jpg`.

## Today daily-lens checkpoint - July 1, 2026

This pass improves the existing daily-focus rail rather than adding another
panel. The rail now starts with a compact visual lens that summarizes the same
four high-frequency signals before the individual cells.

What changed:
- Added `focusBalanceLens` inside `AtriaDailyFocusRail`.
- The lens shows `Daily lens`, the primary recovery readout, four proportional
  bars derived from existing item progress, and the item count.
- It reuses existing rail items (`Recovery`, `Strain`, `Sleep`, `Live`) and
  does not add a new readiness grade, new colors, or a new data pipeline.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- Debug simulator build passed.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-overview-segment today --atria-ui-fixture daily-focus-rail`.
- Runtime UI snapshot showed `Daily lens`, `Recovery --`, `Strain 0.0`,
  `Sleep --`, `Live Off`, and the four rail cells.
- Visual evidence: `artifacts/simulator/today-daily-lens.jpg`.

## Workout detection review-path checkpoint - July 1, 2026

This pass makes ambiguous workout detection feel safer and more correctable.
The in-progress detection card now explains the review path before suggested
labels, so strap-HR evidence does not read like an irreversible auto-workout
verdict.

What changed:
- Added `workoutReviewPathStrip` to `AtriaWorkoutDetectionBanner`.
- The strip shows `1 Strap HR`, `2 Window`, and `3 Label` before likely labels.
- The copy and accessibility label explicitly frame the flow as strap evidence,
  adjustable timing, then label/exercise confirmation.
- Detection thresholds, source boundaries, notifications, and save semantics
  are unchanged.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with
  `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-detection`.
- Runtime UI snapshot showed `Workout review path: strap heart rate evidence,
  adjustable window, then label and exercises.`, plus `1`, `Strap HR`, `2`,
  `Window`, `3`, and `Label`.
- Visual evidence: `artifacts/simulator/workout-detection-review-path.jpg`.

## Sleep review decision-path checkpoint - July 1, 2026

This pass makes the morning sleep card more explicitly user-led. A detected
main-sleep or nap candidate now shows the correction path before the impact
copy and buttons, so the user can see that Atria expects review rather than
blind confirmation.

What changed:
- Added `sleepReviewDecisionStrip` to `AtriaSleepReviewCard`.
- The strip shows `1 Window`, `2 Sleep/Nap`, and `3 Save` using the detected
  candidate type.
- The accessibility label states the full decision path: adjust the window,
  choose sleep or nap, then save.
- Sleep detection, candidate promotion, recovery effects, and notification
  scheduling are unchanged.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with
  `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`.
- Runtime UI snapshot showed `Sleep review path: adjust the window, choose
  sleep or nap, then save.`, plus `1`, `Window`, `2`, `Sleep`, `3`, and `Save`.
- Visual evidence: `artifacts/simulator/sleep-review-decision-path.jpg`.

## Live workout target-strain checkpoint - July 1, 2026

This pass makes the full-screen workout HUD more actionable while preserving
the existing visual thesis. The active workout screen now shows the user's
recovery-scaled strain target directly under the HR zone focus card, so the
user can glance at whether to build, hold, or ease.

What changed:
- `AtriaLiveWorkoutView` now receives `strainTarget` from
  `heroStore.state.guidance.target`.
- Added `strainTargetCard` to the live workout HUD.
- The card shows current strain, target strain, and a compact cue:
  `build`, `hold`, `ease`, or `building` while target guidance is still learning.
- No new metrics pipeline was added; the card reuses existing live strain and
  existing guidance target values.
- The learning state is honest: when the target is unavailable, the HUD shows
  `Learning` instead of inventing a goal.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with
  `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture live-zone --atria-show-workout`.
- Runtime UI snapshot showed `Target strain. Current 10.0, target Learning,
  building.`, plus `Target strain`, `Now`, `Target`, `Cue`, and `End workout`.
- Visual evidence: `artifacts/simulator/live-workout-target-strain.jpg`.

## Live workout target-state fixture checkpoint - July 1, 2026

This pass adds a safe visual proof path for the target-strain card's real
states. Production still uses the guidance target from the hero store; the new
flags only override the HUD target in DEBUG simulator fixtures so the build,
hold, and ease states can be visually checked without fabricating production
guidance.

What changed:
- Added `effectiveStrainTarget` inside `AtriaLiveWorkoutView`.
- Added DEBUG-only launch flags: `live-workout-target-build`,
  `live-workout-target-hold`, and `live-workout-target-ease`.
- The `Target strain` value, progress fill, target notch, and cue now read from
  the effective target.
- The real app path is unchanged: `AtriaHomeView` still passes
  `model.heroStore.state.guidance.target` into the live workout screen.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture live-zone --atria-show-workout live-workout-target-hold`.
- Runtime UI snapshot showed `Target strain. Current 10.0, target 10.0, hold.`,
  plus `Target strain`, `Now`, `Target`, `Cue`, `10.0`, `hold`, and
  `End workout`.
- Visual evidence: `artifacts/simulator/live-workout-target-hold.jpg`.

## Workout detection prompt gating checkpoint - July 1, 2026

This pass reduces false-positive feeling in the live workout prompt. Atria now
has two distinct inline states: a quiet observing state while strap-HR evidence
is still building, and a shorter review-ready state only after the strong
sample/strain/resting-HR gate is met.

What changed:
- Added `isReviewReady`, `headline`, `subtitle`, and `primaryTitle` to
  `AtriaWorkoutDetectionPrompt`.
- The review-ready threshold is explicit in the prompt model:
  `samples >= 900 && strain >= 8 && bpmOverRest >= 35`.
- The default DEBUG `workout-detection` fixture now shows the softer
  `Watching effort` state.
- Added a DEBUG `workout-detection-ready` fixture for the review-ready state.
- The inline home banner no longer dumps label/exercise chips before the user
  enters the guided review flow. The banner shows the visual path; the review
  sheet owns type and exercise selection.
- The observing state disables the primary review action and shows
  `Observe -> Settle -> Ask` with `Keep wearing`.
- The ready state shows `Review this workout`, `Strap HR -> Window -> Label`,
  and a visible `Review workout` CTA that is not buried behind the tab chrome.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-detection`.
- Runtime UI snapshot showed `Watching effort`, `Atria is waiting for stronger
  strap evidence.`, `Observe`, `Settle`, `Ask`, `Likely`, `7 min`, and
  `Keep wearing`.
- Debug build relaunched with `--atria-ui-fixture workout-detection-ready`.
- Runtime UI snapshot showed a tappable `Review workout` button plus
  `Review this workout`, `Sustained strap HR is ready to confirm.`, `Strap HR`,
  `Window`, and `Label`.
- Visual evidence:
  `artifacts/simulator/workout-detection-observing-gated.jpg` and
  `artifacts/simulator/workout-detection-ready-gated.jpg`.

## Workout review notification gating checkpoint - July 1, 2026

This pass keeps workout review notifications from feeling naggy. Low-confidence
workout-like efforts may still appear inside Atria for optional review, but they
no longer generate a push notification.

What changed:
- Added `workoutReviewCandidateIsPushWorthy(_:)` in
  `LocalNotificationScheduler`.
- Workout review notifications now require either a real workout candidate or
  medium/high confidence.
- Low-confidence candidates return a skipped decision with reason
  `candidate_visible_in_app_not_push_worthy`.
- Notification title for non-workout review-worthy efforts is now
  `Review effort` instead of `Possible workout?`.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Trend current-position band checkpoint - July 1, 2026

This pass makes the Overview Trends card easier to read at a glance. Instead of
only showing summary numbers and a chart, the selected metric now gets a compact
low/now/high band that pins the latest value inside the selected range.

What changed:
- Added `AtriaTrendRangePositionBand` to `AtriaTrendChart`.
- The band renders when the selected range has at least three saved points.
- It shows `Current position`, a low-to-high tinted rail, a latest-value marker,
  and compact `Low`, `Now`, and `High` labels.
- Metric-specific language keeps interpretation useful without grading:
  resting HR uses `easier side` / `loaded side`, strain uses `light side` /
  `high side`, and HRV uses `low side` / `high side`.
- No new data path was added; the band reuses the already prepared chart series.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot showed `Current position. Latest 60 bpm, low 58 bpm,
  high 62 bpm, middle of range.`, plus `Low`, `Now`, and `High`.
- Visual evidence:
  `artifacts/simulator/trends-current-position-band-top.jpg` and
  `artifacts/simulator/trends-current-position-band.jpg`.

## Sleep review classification-lens checkpoint - July 1, 2026

Superseded note:
- The classification lens described here was removed by the later
  **Sleep review actions-first checkpoint** because it repeated information
  already present in the state header, night arc, decision pulse, and window
  quality strip. Do not reintroduce `sleepReviewClassificationLens` unless the
  card is redesigned to keep Confirm/Adjust immediately visible.

This pass tightens the morning sleep/nap review card without changing detection
rules. The user now sees what Atria thinks the candidate is and what confirming
it will affect before the decision path and buttons.

What changed:
- Added `sleepReviewClassificationLens` to `AtriaSleepReviewCard`.
- The lens shows three compact visual chips: `Detected`, `Impact`, and
  `Signal`.
- Main-sleep candidates show `Sleep` and `Recovery`; nap candidates show
  `Nap` and `Separate`.
- The card still keeps the existing guided path: adjust the window, choose
  sleep/nap, then save.
- No sleep/nap classifier, recovery scoring, notification scheduling, or
  confirmation behavior changed in this pass.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`.
- Runtime UI snapshot showed `Sleep classification lens. Detected sleep.
  Impact recovery. Signal Debug Fixture Pending Review.`, plus `Detected`,
  `Sleep`, `Impact`, `Recovery`, `Signal`, and the existing decision path.
- Visual evidence:
  `artifacts/simulator/sleep-review-classification-lens.jpg`.

## Trend range assessment checkpoint - July 1, 2026

This pass adds a more WHOOP-like period assessment to Overview Trends without
turning it into a text-heavy report or adding a fake grade. The selected range
now compresses the metric into average, movement, and rhythm bars before the
deeper readout/chart.

Research/context:
- Current WHOOP-style trend surfaces emphasize week/month context around
  recovery, strain, sleep, stress, HRV/RHR, zones, sleep debt, consistency, and
  performance assessments.
- A sidecar code explorer confirmed `AtriaTrendChartCard` is the right Overview
  surface for a compact assessment because detail sheets and History already
  have deeper range summaries.

What changed:
- Added `AtriaTrendRangeAssessment` in `AtriaTrendChart`.
- Added `AtriaTrendRangeAssessmentCard` below the existing range lens.
- The card renders when the selected metric/range has at least three samples.
- It shows three compact bars: `Avg`, `Move`, and `Rhythm`.
- The assessment reuses already prepared samples/previous samples, so it adds
  no new history queries and does not change detection, scoring, or storage.
- Wording stays neutral: `steady`, `mixed`, or `variable` instead of a
  red/green grade.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot showed `Month assessment. Average 60 bpm, movement -2
  bpm, consistency steady.`, plus `Avg`, `Move`, and `Rhythm`.
- Visual evidence:
  `artifacts/simulator/trends-range-assessment.jpg`.

## Workout review save-receipt checkpoint - July 1, 2026

This pass improves the final step of the guided workout review flow. The user
now gets a visual receipt before saving, so the confirmation feels like a
clear decision instead of another form row.

Research/context:
- WHOOP-style activity review depends on clean post-effort confirmation:
  auto-detection should wait until heart rate has settled, and users still need
  a simple way to review the window, activity type, and optional details.
- Atria already had a guided time/type/exercise flow; this pass makes the
  final save step match that visual guidance.

What changed:
- Added `summaryReceiptLens` to `AtriaWorkoutReviewFlow.summaryStep`.
- The receipt shows `Ready to save`, `Strap HR`, and compact visual metrics for
  `Window`, `Type`, and `Moves`.
- Added `--atria-workout-review-summary-step` DEBUG launch support so this step
  can be visually checked directly.
- No workout detection gates, saving semantics, exercise catalog, or source
  rules changed. The saved workout remains user-confirmed strap-HR metadata.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-review-flow --atria-workout-review-summary-step`.
- Runtime UI snapshot showed `Workout save receipt. Window 42m. Type Strength.
  Exercises 0. Source strap heart rate.`, plus `Ready to save`, `Strap HR`,
  `Window`, `Type`, `Moves`, and the `Save workout` button.
- Visual evidence:
  `artifacts/simulator/workout-review-summary-receipt.jpg`.

## Header live HR-zone checkpoint - July 1, 2026

This pass makes the live heart-rate zone visible from the top chrome, so the
user can glance at the zone without scrolling back to the hero card.

What changed:
- Added `AtriaHeaderZoneIndicator` to `AtriaHomeTopChrome`.
- The indicator appears only when a live `heartRateZone` exists from the strap
  pulse store.
- It shows a compact six-segment zone rail plus the current `Z#` and zone name.
- The full hero `AtriaHeartRateZoneRail` / `AtriaHeartRateZoneLens` remains
  unchanged; this is a compact always-visible glance, not a duplicate detail
  card.
- No heart-rate-zone math, detection, storage, or workout behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding live-zone`.
- Runtime UI snapshot showed `Heart rate zone Zone 2, Endurance.`, plus
  `Connection Live`, `Strap battery 72%, Strap not charging.`, and the full
  hero `Heart-rate zone lens. Zone 2, Endurance, reserve 64 percent, Build.`
- Visual evidence:
  `artifacts/simulator/header-live-hr-zone.jpg`.

## Workout review prompt gate checkpoint - July 1, 2026

This pass reduces noisy workout false-positive prompts without throwing away
strap-HR evidence. Low-confidence activity evidence can still remain in the
saved/replay pipeline, but the main Overview review banner now only interrupts
the user when the candidate is strong enough to review.

What changed:
- Added `WorkoutReviewCandidate.isReviewPromptWorthy`.
- The shared prompt-worthy rule is `kind == .workout || confidence != .low`.
- `AtriaHomeView.refreshSavedWorkoutReviewCandidate` now hides low-confidence
  candidates from the main Overview review banner.
- `LocalNotificationScheduler` now uses the same shared rule for workout
  review push-worthiness, instead of duplicating the condition.
- The saved-workout-review debug fixture now uses a medium-confidence candidate
  so visual checks still exercise the worthy review-card path.
- No detection thresholds, strap-source rules, workout saving, exercise
  selection, or HealthKit export behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-fixture
  saved-workout-review`.
- Visual evidence showed the worthy review card still appears with detected
  window, strap-HR rail, zone strip, signal pill, and `Review & label` /
  `Not this` actions:
  `artifacts/simulator/workout-review-prompt-worthy-gate.jpg`.

## Journal impact map checkpoint - July 1, 2026

This pass makes behavior impact easier to scan before reading details. The
Journal `Impacts` card now opens with a compact map: center is neutral, left is
`Watch`, and right is `Support`. Existing local behavior summaries drive the
node positions; no new score, grade, color severity, or backend correlation
logic was added.

What changed:
- Added `AtriaJournalImpactMap` above the existing impact compass.
- The map renders up to five behavior tags as icon nodes on a neutral axis.
- Node position uses the existing `impactDelta` and `impactProgress`; unknown
  impact stays centered.
- The existing `Impact compass`, focus row, and impact bars remain below the
  map for detail.
- Added static coverage for the map, neutral-axis language, and node-position
  helper.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug build installed and launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment journal --atria-ui-fixture journal-impact-focus`.
- Visual evidence:
  `artifacts/simulator/journal-impact-map.jpg`.

Next recommended small slice from the sidecar explorer:
- Add a compact sleep-glance morning status strip for the confusing
  nap-only / missing-main-sleep state.
- Suggested shape: `Wear` / `Sync` / `Review` or `Sync` / `Detect` / `Review`
  with only the current step highlighted.
- Candidate files:
  `Atria/Atria/AtriaOverviewSections.swift` around `sleepGlanceValueText`,
  `sleepGlanceTitleText`, `sleepGlanceDetailText`, `sleepGlanceTint`, and
  `AtriaSleepHistoryGlanceCard`.
- Existing fixtures to reuse: `pending-sleep-review`, `sleep-sync-needed`.
  Add a small `nap-only-morning` fixture if needed.

## Sleep nap-only morning status checkpoint - July 1, 2026

This pass implements the recommended nap-only morning clarification without
loosening sleep detection or recovery math.

What changed:
- `AtriaSleepHistoryGlanceCard` now derives a compact
  `AtriaSleepMorningStatus` from cached sleep history.
- Confirmed nap evidence maps to a visual `Wear -> Sync -> Review` strip with
  `Sync` highlighted, making it clear the nap is saved separately while main
  overnight sleep still needs evidence.
- Confirmed main sleep keeps the existing stage/consistency legend, so the
  status strip only appears when the morning flow needs action.
- Added a DEBUG-only `nap-only-morning` fixture for repeatable simulator review.
- The fixture also skips top interruption cards in DEBUG so visual evidence can
  land on the relevant sleep-history card.

What did not change:
- No sleep detection thresholds changed.
- No nap/main-sleep classification changed.
- No recovery, notification, HealthKit, storage, or backfill behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug app installed/launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture nap-only-morning`.
- Runtime UI automation snapshot proved `Sleep history`,
  `Nap · saved separate`, `24m`, and
  `Morning sleep status. Sync, nap saved separately and main sleep still needs overnight evidence.`
- Visual evidence:
  `artifacts/simulator/sleep-nap-only-morning-status.png`.

## Workout held-signal trust checkpoint - July 1, 2026

This pass improves the false-positive workout experience without loosening the
auto-detection gate. When Atria deliberately suppresses a workout review because
live HR is still settling or saved evidence is only possible effort, Overview can
show a quiet non-action banner instead of either interrupting or going silent.

What changed:
- Added `WorkoutReviewHoldState` for two conservative hold states:
  `waitingForSettle` and `possibleSignal`.
- `refreshSavedWorkoutReviewCandidate` now sets a hold state when live HR is
  still above the settle threshold or when the latest candidate is not
  review-prompt-worthy.
- Added `AtriaWorkoutReviewHoldBanner`, a visual-only strap-HR lens with
  `Observe -> Settle -> Ask`.
- Added DEBUG fixtures:
  `workout-review-hold-settle` and `workout-review-hold-possible`.
- The possible-effort banner avoids fake BPM text; it uses an icon rail and
  clear copy: `Saved as possible effort. No review prompt until strap capture is
  stronger.`

What did not change:
- No workout detection thresholds changed.
- No candidate aggregation, notification push-worthiness, saving, HealthKit, or
  exercise-label behavior changed.
- The review and notification paths still use `WorkoutReviewCandidate.isReviewPromptWorthy`.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.
- Debug app installed/launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-fixture workout-review-hold-possible`.
- Runtime UI snapshot proved the possible-effort hold banner, `Strap HR`,
  `Saved as possible effort. No review prompt until strap capture is stronger.`,
  and the visual steps `Observe`, `Settle`, `Ask`.
- Visual evidence:
  `artifacts/simulator/workout-review-hold-possible.png`.

## Workout false-positive prompt gate checkpoint - July 1, 2026

This pass tightens the boundary between diagnostic workout-like evidence and a
user-facing workout review prompt. The goal is WHOOP-like trust: Atria should
keep learning from strap HR, but it should not ask "was this a workout?" for
ordinary elevated HR or short fragmented chunks.

What changed:
- `WorkoutReadiness.reviewWorthyCandidate` and
  `WorkoutReplaySummary.bestReviewWorthyCandidate` now require stronger prompt
  evidence before saved candidates appear in Overview, daily rollups, detected
  activities, or workout-review notifications.
- Review prompts now require at least 35 minutes of observed strap-HR evidence,
  85% stream coverage, and peak HR at least 40 bpm over rest.
- Near-miss prompts now require a more sustained workout-band signal:
  12 minutes elevated or a 6-minute continuous elevated bout.
- Strength-like prompts now require a stronger borderline signal:
  18 minutes borderline elevated and a 6-minute continuous borderline bout.

What did not change:
- Fully ready workouts still pass the existing strict workout gate.
- The detector still logs/learns near-miss and strength-like evidence.
- No phone-motion, HealthKit step, saving, export, exercise-label, or Liquid
  Glass UI behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Debug app installed/launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture saved-workout-review`.
- Visual sanity screenshot:
  `artifacts/simulator/workout-review-prompt-gate-sanity.png`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Trends signal stack checkpoint - July 1, 2026

This pass makes the Trends card more WHOOP-like at a glance: one selected
range should explain recovery/load direction visually before the user digs into
metric toggles or text.

What changed:
- Added `AtriaTrendSignalStack` below the Trends range lens.
- The stack shows HRV, resting HR, and Strain together as compact now/prior
  lanes for the selected day/week/month/quarter/6M range.
- It reuses the existing precomputed `AtriaTrendPeriodReadout`, so the render
  path does not do new filtering or reducing inside SwiftUI body code.
- The stack uses the existing `atriaInsetCard` chrome to stay inside Atria's
  Native Liquid Glass design language.

What did not change:
- No analytics formulas, detection thresholds, workout prompts, recovery math,
  storage, or HealthKit behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Debug app installed/launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Visual evidence:
  `artifacts/simulator/trends-signal-stack.png`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Always-visible HR zone ladder checkpoint - July 1, 2026

This pass tightens the persistent heart-rate zone affordance. The user should
not have to start a workout to understand the current heart-rate zone.

What changed:
- `AtriaHeaderZoneIndicator` now shows a tiny 0-5 color ladder in the top
  chrome whenever live strap HR has a personal HR-reserve zone.
- The active zone segment is taller and keeps a compact visible `Zx` readout;
  the hero card still shows the full zone name and reserve detail.
- This builds on the existing `Metrics.heartRateZone(bpm:rest:max:)` personal
  HR-reserve calculation and does not add any phone-motion source.

What did not change:
- No zone thresholds, workout detection, haptics, notifications, HealthKit, or
  storage behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Debug app installed/launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-fixture live-zone`.
- Visual evidence:
  `artifacts/simulator/header-zone-ladder.png`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Workout review glass footer checkpoint - July 1, 2026

This pass fixes a small but important interaction detail in the guided workout
review flow: Back/Continue should feel like a native bottom action dock, not a
flat opaque slab and not an overlay hiding exercise choices.

What changed:
- `AtriaWorkoutReviewFlow` now keeps the scrollable review content and the
  bottom actions in separate vertical regions.
- The action area uses a contained `atriaInsetCard` glass dock instead of a
  full-width opaque `systemBackground` rectangle.
- The crowded exercise-selection step was used as the visual target because it
  is the easiest place for the footer to cover real selectable content.

What did not change:
- No workout detection thresholds, strap-source rules, confirmation persistence,
  HealthKit export, exercise catalog, or auto-save behavior changed.
- The guided flow remains: adjust window, choose activity type, optionally add
  exercises, then save the strap-HR workout.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Debug app installed/launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-fixture workout-review-flow --atria-workout-review-exercises-step`.
- Visual evidence:
  `artifacts/simulator/workout-review-flow-glass-footer-separated.png`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Workout review save receipt checkpoint - July 1, 2026

This pass makes the final workout-review step feel like a visual confirmation,
not just another form page. Before saving, the user can see exactly what Atria
will store from the strap-HR workout.

What changed:
- `AtriaWorkoutReviewFlow` summary now shows a compact save receipt with:
  window duration, selected activity type, movement count, source `Strap HR`,
  and the peak heart-rate zone rail.
- Selected exercises, when present, are shown as a local movement list inside
  the receipt instead of as loose text below the card.
- The receipt stays inside the existing Native Liquid Glass card language and
  reuses `AtriaWorkoutZoneEvidenceStrip`.

What did not change:
- No workout detection thresholds, strap-source rules, confirmation persistence,
  HealthKit export, activity catalog, or notification behavior changed.
- The flow remains guided: window, type, optional exercises, save.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Debug app installed/launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-fixture workout-review-flow --atria-workout-review-summary-step`.
- Visual evidence:
  `artifacts/simulator/workout-review-save-receipt.png`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## History daily rollup readability checkpoint - July 1, 2026

This pass makes saved activity history easier to scan. The daily history surface
now leads with recent rollups instead of burying them below trend diagnostics,
and each day uses compact chips instead of a long developer-style sentence.

What changed:
- History now shows **Daily rollups** above **Trends**, so recent saved activity
  evidence is visible first.
- `DailyRollupRow` now uses visual chips for saved duration, confirmed workouts,
  auto workouts, review candidates, rest context, and sleep context.
- The row strain value uses the existing electric strain color instead of plain
  secondary text, and workout/activity icon tint is aligned with the existing
  orange/cyan activity language instead of arbitrary green.
- Added a debug-only `--atria-ui-screen history` route so HistoryView can be
  screenshot-verified directly with fixtures.

What did not change:
- No history rollup computation, workout detection thresholds, sleep logic,
  storage, HealthKit export, or notification behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed.
- Debug app installed/launched on simulator
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-screen history --atria-ui-fixture history-activity-rhythm`.
- Visual evidence:
  `artifacts/simulator/history-rollup-chips.png`.
- Release iPhoneOS build passed with `CODE_SIGNING_ALLOWED=NO`.

## Workout review notification copy checkpoint - July 1, 2026

This pass makes workout-review notifications sound like a user decision instead
of a diagnostic line.

What changed:
- Workout review notification title is now **Was this your workout?** for
  review-worthy workout candidates.
- The body now says the duration, time window, and action:
  review the window, label it, or dismiss.
- Removed peak-BPM/log-style wording from the notification body; detailed HR
  evidence remains in the in-app review flow.

What did not change:
- No notification scheduling cadence, push-worthiness gate, workout detector,
  dismissal memory, storage, HealthKit export, or strap-source boundary changed.
- Notifications still require `candidate.isReviewPromptWorthy`.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.

## Workout review concise-flow checkpoint - July 1, 2026

This pass trims the guided workout-review sheet so it stays visual and
decision-led instead of reading like a diagnostic explanation.

What changed:
- The sheet header subtitle is shorter:
  **Review the strap-HR window, label it, then save.**
- The decision lens accessibility/copy now reads as the three actions:
  confirm, adjust time, or reject.
- Time, Exercises, and Save step subtitles were shortened so the visual chips
  and footer actions carry the flow.
- No workout detection, saving, notification, HealthKit, or strap-source logic
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33`.
- Runtime UI snapshot showed the concise strings:
  `Review the strap-HR window, label it, then save.`,
  `Workout review choices. Confirm, adjust time, or reject.`,
  and `Set the real window.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-concise-time-step.jpg`.

## Sleep review strap-HR clarity checkpoint - July 1, 2026

This pass follows the fresh wake-up device pull: Atria collected the overnight
strap-HR window, but correctly did not auto-confirm it because motion/history
validation was stale. The UI now makes that state understandable instead of
looking like a missed or vague detection.

Physical-device evidence from `artifacts/device-sleep-wakeup-20260701-090427`:
- Overnight candidate: `2026-07-01 00:33:01 IST` to `08:46:29 IST`.
- Duration: `493.5m`.
- Samples: `30,773` strap-HR points.
- HR: avg `64.5`, min `44`, max `115`.
- Sleep audit: `overnight_sleep`, `ready=0`,
  blocker `sleep_motion_unvalidated_historical_stale`.

What changed:
- Main-sleep review card title is now **Review last night's sleep**.
- The card subtitle now says Atria captured the overnight strap signal and asks
  the user to confirm or adjust before it counts.
- HR-only review evidence is shown as **Strap HR** in the card and notification.
- The compact decision path now reads **Strap HR -> Review -> Save**.
- The notification title for main sleep now matches the review card:
  **Review last night's sleep**.
- The pending-sleep-review fixture now uses `review_needed`, so visual checks
  exercise the same strap-HR review state seen on the physical iPhone.

What did not change:
- No sleep auto-confirm thresholds, recovery effects, HealthKit export,
  storage schema, or motion-validation policy changed.
- HR-only overnight candidates still require user confirmation before they can
  affect recovery.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33`.
- Runtime UI snapshot showed:
  `Review last night's sleep`,
  `Atria captured the overnight strap signal. Confirm or adjust before it counts.`,
  `Strap HR`,
  and `Sleep review path: strap heart rate, review the window, then save.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-strap-hr.jpg`.

## Live HR zone mini-rail checkpoint - July 1, 2026

This pass strengthens the always-visible heart-rate-zone experience without
adding another text-heavy card. The top chrome already shows the current zone;
the bottom live accessory now uses a tiny six-segment rail too, so opening the
app gives an immediate Zone 0-5 read.

What changed:
- `AtriaLiveZoneAccessoryPill` now renders a compact six-segment mini rail
  beside the current zone label.
- The highlighted segment follows `Metrics.heartRateZoneTint(index)` and
  `zone.index`, matching the existing personal HR-reserve zone model.
- The accessory keeps the short `Z0`-`Z5` label and accessibility now says the
  full zone title/name.

What did not change:
- No heart-rate-zone thresholds, live HR sourcing, strap-source boundary,
  workout detection, battery state, or connection logic changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture live-zone`.
- Runtime UI snapshot showed:
  `Heart rate zone Zone 2, Endurance.`,
  `Z2`,
  `Live heart rate`,
  and `Heart-rate zone lens. Zone 2, Endurance, reserve 64 percent, Build.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-live-hr-zone-mini-rail.jpg`.

## Trends range language polish checkpoint - July 1, 2026

This pass keeps the existing visual Trends system but makes the range language
feel less developer-ish and closer to a quick product read.

What changed:
- The Trends header now uses `range.headerLabel`, so the day range reads
  **Today** instead of **Last 1 day**.
- The 90-day range now presents as **3M** / **3 months** instead of
  **Q** / **Quarter**.
- The visible range strip now reads **D W M 3M 6M**, matching the simple range
  rhythm used by current wearable apps.

What did not change:
- No trend calculations, range durations, chart scaling, saved-session
  filtering, metric thresholds, or data sources changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot showed:
  `Last 30 days · 31 sessions`,
  range tabs `Day`, `Week`, `Month`, `3M`, `6M`,
  rhythm strip labels `D`, `W`, `M`, `3M`, `6M`,
  and `3M trend range, 70 saved points`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-3m-range-polish.jpg`.

## Trends natural narrative labels checkpoint - July 1, 2026

This pass keeps compact range controls while making trend cards read naturally.
The selected control can say **3M**, but the insight text now says
**3 months**.

What changed:
- `AtriaTrendPeriodReadout` now has a separate `narrativeRangeLabel`.
- `AtriaTrendRange.narrativeLabel` drives hero titles and prior-period copy.
- Trend titles now read **Steady 3 months** / **Strain-heavy 3 months**
  instead of lowercased control shorthand like `3m`.

What did not change:
- No trend calculations, selected range duration, chart data, chart scaling,
  metric thresholds, storage, or data sources changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture trend-prior-comparison`.
- Runtime UI after tapping the range rhythm strip `3M` button showed:
  `Last 3 months · 70 sessions`,
  selected tab `3M`,
  `Period report. Steady 3 months...`,
  and title `Steady 3 months`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-3m-natural-narrative.jpg`.

## Trends chart semantic summary checkpoint - July 1, 2026

This pass keeps the trend chart visually unchanged while giving the graph a
single concise semantic summary. It improves VoiceOver and automated visual
checks without adding more visible text.

What changed:
- `AtriaTrendChartCard.chart` now ignores individual chart marks for
  accessibility and exposes `chartAccessibilityLabel`.
- The chart label summarizes metric, range, saved-session count, latest value,
  average, range, and prior/change context.

What did not change:
- No chart marks, chart styling, trend calculations, selected range duration,
  metric thresholds, storage, or data sources changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture trend-prior-comparison`.
- Runtime UI after selecting `3M` and scrolling to the chart showed:
  `Resting HR trend, last 3 months, 70 saved sessions. Latest 60 bpm, average 61 bpm, range 58-64 bpm, change -3 bpm.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-chart-accessibility-summary.jpg`.

## Workout review expanded label checkpoint - July 1, 2026

This pass makes the workout confirmation flow feel closer to a real wearable
activity review without changing the Liquid Glass sheet structure. Users still
move through Time -> Type -> Exercises -> Save, but the Type step now has more
useful labels once they need to classify what actually happened.

What changed:
- Expanded `AtriaWorkoutActivityType.subtypeOptions` for Strength, Sport,
  Cardio, HIIT, Functional, and Dance.
- Added strength styles like `Push`, `Pull`, `Upper body`, `Powerlifting`, and
  `Bodybuilding`.
- Added broader sport/activity labels including `Soccer`, `Pickleball`,
  `Boxing`, `Martial arts`, `Jiu jitsu`, `Climbing`, and `Hiking`.
- Added cardio/functional labels such as `Incline walk`, `Jump rope`,
  `Cross training`, `Kettlebell`, and `Carry work`.

What did not change:
- No detector thresholds, workout-candidate logic, sensor sources, persistence
  schema, notification gating, or footer layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-review-flow --atria-workout-review-type-step`.
- Runtime UI snapshot showed `What type was it?`, suggested type cards,
  `Selected type Strength. Push.`, the full activity grid, `Style`, `Push`,
  `Pull`, `Upper body`, `Powerlifting`, `Bodybuilding`, and separated
  `Back`/`Continue` footer actions.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-type-expanded-labels-top.jpg`
  and
  `artifacts/visual-checks/simulator/20260701-workout-review-type-expanded-labels-styles.jpg`.

## Saved workout review timing checkpoint - July 1, 2026

This pass makes the saved workout-review card explain the wearable-app mental
model visually: Atria asks after an effort window has ended, the user decides,
and that correction should make the next classification better.

What changed:
- Added a compact `Ended` / `Ask` / `Learn` strip to
  `AtriaSavedWorkoutReviewBanner`.
- Kept the existing detected-window rail, HR zone strip, peak/average/signal
  pills, review path, and `Review & label` / `Not a workout` actions.
- Used short visual labels instead of adding paragraph copy.

What did not change:
- No detector thresholds, workout-candidate logic, source boundaries,
  persistence schema, notification scheduling, or action behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture saved-workout-review`.
- Runtime UI snapshot showed `Effort ready to review`, `Detected window`,
  `Zone 3`, `Peak`, `Average`, `Signal`, `Ended`, `Settled`, `Ask`,
  `You decide`, `Learn`, `Next time`, `Window`, `Type`, `Exercises`,
  `Review & label`, and `Not a workout`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-saved-workout-review-ended-ask-learn.jpg`.

## Sleep review impact checkpoint - July 1, 2026

This pass makes pending sleep review clearer after overnight strap capture:
the user sees that Atria captured strap HR, they can fix the window, and a main
sleep confirmation unlocks recovery. Naps still read as separate.

What changed:
- Added a compact `Captured` / `Review` / `Recovery` impact strip to
  `AtriaSleepReviewCard`.
- Removed the older redundant `Strap HR` / `Review` / `Save` path strip after
  visual QA showed the extra row pushed actions too low.
- Kept the duration hero, start/end/signal pills, main sleep/nap window strip,
  classification lens, and `Confirm sleep` / `Adjust` / `Not me` actions.

What did not change:
- No sleep detection thresholds, candidate selection, nap-vs-main-sleep logic,
  persistence schema, notification scheduling, or sensor source logic changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture pending-sleep-review`.
- First visual pass showed the actions were pushed too low; the redundant path
  strip was removed and the fixture was rebuilt.
- Final runtime UI snapshot showed `Review last night's sleep`, `7h 18m`,
  `Strap HR`, `Main sleep`, `Full night`, `Before recovery`, `Captured`,
  `Review`, `Recovery`, `Unlocks`, plus visible `Confirm sleep`, `Adjust`,
  and `Not me` actions.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-impact-actions-visible.jpg`.

## Trends hero cue rail checkpoint - July 1, 2026

This pass makes the Trends hero more immediately actionable without adding a
new card. The period summary now surfaces the simple cue, recovery reserve, and
load pressure before the user reaches the deeper balance map.

What changed:
- Added `trendCueRail` inside `AtriaTrendPeriodHeroCard`.
- The hero now shows compact `Cue`, `Reserve`, and `Load` pills above the
  existing HRV/RHR/Strain gauges.
- The existing period accessibility summary now includes reserve and load
  percentages.

What did not change:
- No trend calculations, range durations, chart marks, data source, selected
  metric behavior, or saved-session filtering changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot showed `Period report. Strain-heavy month. Recover.
  Reserve 74 percent. Load 53 percent...` plus visible `Cue`, `Recover`,
  `Reserve`, `74`, `Load`, `53`, `HRV`, `RHR`, and `Strain`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-hero-cue-rail.jpg`.

## Strap-step product copy checkpoint - July 1, 2026

This pass removes developer/lab wording from strap-step surfaces while keeping
the strap-only boundary explicit. The UI now says strap movement is calibrating
or estimated instead of exposing `research-tier` style language.

What changed:
- Overview strap-step cards now use `Calibrating`, `Strap movement estimate`,
  and `Strap step estimate`.
- Strap-step target zones now say `Strap movement goal` and explain that steps
  stay labeled as estimates until strap movement calibration is validated.
- Settings now says `Daily strap-step and estimated active calories goals` and
  `Strap steps goal`.
- The Overview target editor now says `Reset strap steps goal`, and its helper
  text says `strap steps` / `sensor cards` instead of generic steps/research.

What did not change:
- No step calculations, strap IMU parsing, source boundaries, target math,
  widget ordering behavior, or settings persistence changed.

Validation:
- Search confirmed the old phrases are gone from `Atria/Atria` and
  `test_handoff_static_checks.py`: `Daily steps`, `Steps goal`,
  `research-tier`, `Strap step research goal`,
  `Strap steps from movement research`, `Strap step research is waiting`,
  `Strap research`, `Research strap-step`, `steps, and research`,
  `Reset steps goal`, and `strap-step research`.
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33`.
- Runtime UI snapshot in Settings showed `Activity, Daily strap-step and
  estimated active calories goals.` and `Strap steps goal, 8,000`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-settings-strap-step-goal-copy.jpg`.

## Review notification decision-copy checkpoint - July 1, 2026

This pass tightens notification language so sleep/workout prompts feel like
clear user decisions instead of diagnostic labels.

What changed:
- Main sleep review notification action now says **Confirm or adjust before it
  unlocks recovery.**
- Low-confidence workout review notification title now says **Was this effort
  a workout?** instead of **Review possible workout**.
- Workout review body now says **Review the window, label it, or dismiss.** or
  **Choose workout, adjust time, or dismiss.**

What did not change:
- No notification scheduling cadence, cooldown, push-worthiness gates,
  sleep/workout detection thresholds, live-capture protection, or notification
  identifiers changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Search confirmed stale current-code/test phrases are gone:
  `Review possible workout`, `mark not a workout`, `Label it, adjust time`,
  and `shapes recovery`.

## Live zone name checkpoint - July 1, 2026

This pass makes the always-visible live heart-rate zone easier to read at a
glance. The top chrome no longer relies on `Z2` plus color alone; it also shows
the zone name when a live zone is available.

What changed:
- `AtriaHeaderZoneIndicator` now shows `zone.shortLabel` and `zone.name`.
- `AtriaLiveZoneAccessoryPill` shows the zone name in the non-inline accessory
  while keeping the compact inline mode short.
- Existing mini zone rails and accessibility labels remain intact.

What did not change:
- No heart-rate zone thresholds, HR data source, haptic logic, workout logic,
  battery state logic, or top-bar actions changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture live-zone`.
- Runtime UI snapshot showed `Heart rate zone Zone 2, Endurance.`, top-chrome
  `Z2`, `Endurance`, and the live hero zone lens with `Zone 2`, `Endurance`,
  `Reserve 64%`, and `Cue Build`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-live-zone-name-top-chrome.jpg`.

## Workout review capture-check checkpoint - July 1, 2026

The gym validation showed workout-like HR chunks but not a confidently stitched
full workout. This pass makes the review sheet more transparent before the user
labels the activity: Atria now shows what it actually captured and whether it is
ready to save as a workout or only as evidence.

What changed:
- `AtriaWorkoutReviewFlow.header` now includes `captureEvidenceStrip` after the
  HR-zone evidence and before confirm/adjust/reject choices.
- The strip shows three compact visual tiles: `Obs`, `Signal`, and `Save`.
- The `Save` tile says `Workout` when the prompt is review-ready, otherwise
  `Evidence`, preserving honest behavior for fragmented capture.
- Accessibility exposes:
  `Workout capture check. Observed ... minutes. Signal .... Save ...`.

What did not change:
- No workout detector thresholds, strap-only data boundary, persistence,
  Health export gating, notification cadence, or exercise catalog behavior
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-review-flow`.
- Runtime UI snapshot showed `Workout capture check. Observed 7 minutes. Signal
  Likely. Save evidence only.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-capture-check.jpg`.

## Metric detail period-report checkpoint - July 1, 2026

This pass extends the WHOOP-like range-report idea into metric detail sheets.
Users opening Recovery/Sleep/etc. now get a compact period report between the
summary strip and prior comparison instead of jumping from summary straight to
the dense chart.

What changed:
- `AtriaMetricDetailSheet.metricChart` now renders
  `AtriaDetailPeriodReportCard` whenever a period summary exists.
- The report shows three compact visual chips: `Now`, `Move`, and `Prior`.
- A small position rail shows where the latest value sits in the selected
  period's range.
- Accessibility exposes:
  `Detail period report. Now ..., move ..., prior ..., average ...`.

What did not change:
- No daily metric preparation, range math, chart scaling, target thresholds,
  persistence, or BLE/data-source behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-overview-segment today --atria-ui-fixture recovery-detail`.
- Runtime UI snapshot showed `Detail period report. Now 62%, move -18%, prior
  -1%, average 73%.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-detail-period-report.jpg`.

## Trends range-report checkpoint - July 1, 2026

Current WHOOP references emphasize weekly, monthly, and 6-month trend patterns
across Strain, Recovery, Sleep, and Stress, plus daily recommendations from the
signals. This pass adds a compact visual report to Atria's Trends surface so the
selected range gives a quick read before the denser graph stack.

What changed:
- `AtriaTrendChartCard` now inserts `AtriaTrendRangeReportCard` after the
  period hero and before the balance/signal maps.
- The report shows three visual tiles: best signal, pressure signal, and next
  action.
- The report also shows compact reserve/load bars for the selected range.
- Accessibility summarizes the same information as:
  `Trend range report. Best signal ..., Pressure ..., Next ..., Reserve ... percent. Load ... percent.`

What did not change:
- No trend data preparation, range math, chart scaling, sleep/workout detection,
  persistence, or BLE/data-source behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-screen overview --atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot showed `Trend range report. Best signal +6 ms. Pressure
  Low. Next Build. Reserve 74 percent. Load 53 percent.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-range-report.jpg`.

## Latest completion status - July 1, 2026

The implementation is now on the completion track, with physical-device Release
proof for the critical readings and a final detector patch for strength-like
workout review. The remaining caveat is intentional: auto-count/export still
stays strict until stream coverage and HR intensity evidence are strong enough,
but review prompts can now surface fragmented strength evidence for user
confirmation instead of silently ignoring it.

Current simulator proof covers the main requested surfaces:

- Today plan:
  `artifacts/visual-checks/simulator/20260701-today-plan-leaner.jpg`.
- Trends ranges and summaries:
  `artifacts/visual-checks/simulator/20260701-trends-range-report.jpg`.
- Workout detection:
  `artifacts/visual-checks/simulator/20260701-workout-detection-signal-language.jpg`.
- Workout review:
  `artifacts/visual-checks/simulator/20260701-workout-review-human-language.jpg`.
- Sleep review:
  `artifacts/visual-checks/simulator/20260701-sleep-review-stale-branch-cleanup.jpg`.
- Live workout:
  `artifacts/visual-checks/simulator/20260701-live-workout-reduce-motion-heart.jpg`.

Physical-device evidence:
- Non-disruptive pull:
  `docs/evidence/final-device/20260701T122817Z-non-disruptive-pull`.
- Release refresh:
  `docs/evidence/final-device/20260701T122906Z-release-refresh`.
- Patched strength-review Release install:
  `docs/evidence/final-device/20260701T123601Z-strength-review-release`.
- Final non-disruptive pull:
  `docs/evidence/final-device/20260701T123939Z-final-nondisruptive-pull`.
- Final physical foreground screenshot:
  `artifacts/visual-checks/physical/20260701-final-physical-atria-foreground.png`.
- The cabled iPhone Release run showed strap HR from `2A37`, live battery from
  `2A19`, `notCharging`, and sleep review notification delivery for the
  overnight window.
- The final physical pull showed Atria running, no listed official WHOOP process,
  live strap battery `58%`, `notCharging`, active journal freshness `fresh`,
  RR present in the active journal, and `phone_motion_sessions=0`.
- The final foreground screenshot showed `Live`, `Strap`, `77 bpm`, HR zone,
  live battery, and a user-facing `Workout ready to review` card with
  `Review & label` and `Not a workout`.
- The overnight sleep window was captured as pending user confirmation:
  July 1, 2026 00:33-08:46 IST, about 8h13m, with 30,773 HR samples and
  23,697 RR values in the non-disruptive pull.
- The patched detector loosens only the review layer: strength-like fragmented
  evidence can become a review prompt at 15+ observed minutes and 40% stream
  coverage, while the strict ready/export gate remains HRR50-based.
- The patched Release build was installed on the physical iPhone and left
  running in normal end-user mode.

Latest validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build passed with `xcodebuild -project Atria/Atria.xcodeproj
  -scheme Atria -configuration Debug -sdk iphonesimulator -destination
  'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath
  build/DerivedData build CODE_SIGNING_ALLOWED=NO`.
- Physical Release build/install passed for `Aman's iPhone`
  (`3803F5B6-1666-56D3-A71A-62F131F6CE3B`) and was relaunched normally by the
  harness after evidence pull.

## Final-track completion audit - July 1, 2026

This audit consolidates the current proof for the broad WHOOP-replacement UI
goal. It does not mark the work complete yet; it records what is now proven and
what still needs a final go/no-go pass.

Current proof coverage:
- **Today / coaching:** `Today's Plan` has a compact visual hierarchy with day
  lane, sleep plan, and balance rail. Visual proof:
  `artifacts/visual-checks/simulator/20260701-today-plan-leaner.jpg`.
- **Trends / ranges / summaries:** Trends now has D/W/M/3M/6M ranges, range
  coverage, answer-first `Range report`, `Balance map`, and denser trend board
  below. Visual proof:
  `artifacts/visual-checks/simulator/20260701-trends-range-report.jpg`.
- **Workout detection:** inline detection uses strap-source language and a short
  Signal / Time / Next decision strip. Visual proof:
  `artifacts/visual-checks/simulator/20260701-workout-detection-signal-language.jpg`.
- **Workout review:** review flow leads the user through time, type, optional
  exercises, and save receipt without dumping everything into one screen. Visual
  proof:
  `artifacts/visual-checks/simulator/20260701-workout-review-human-language.jpg`.
- **Sleep review:** morning review card is action-first, shows Confirm / Adjust
  / Dismiss, and uses Strap / Time / Save plus the night arc. Visual proof:
  `artifacts/visual-checks/simulator/20260701-sleep-review-stale-branch-cleanup.jpg`.
- **Live workout:** HUD shows HR, zone, target lane, source, review state, and
  end action while keeping the repeating heart animation Reduce Motion-safe.
  Visual proof:
  `artifacts/visual-checks/simulator/20260701-live-workout-reduce-motion-heart.jpg`.
- **Source boundary:** static checks cover the no-phone-motion / no-CoreMotion
  step source boundary and forbid reintroducing phone-step wording in the app.
- **Forbidden/rough copy sweep:** current app-code sweep found no forbidden
  placeholder-bypass wording and no iPhone-motion step source. Remaining `Captured` strings are test
  forbidden needles, not mounted UI.

Final blockers before marking the overall goal complete:
- A physical-device Release validation pass still needs to prove live strap HR,
  battery/charging freshness, workout detection/review, and sleep/nap review
  behavior together on the cabled iPhone.
- The final pass should include one short scroll/performance sanity check on
  Today, Trends, live workout, sleep review, and workout review after all current
  changes are in place.
- The handoff file now contains duplicate older checkpoint sections; before a PR
  or final delivery, it should be compacted into a short final state / evidence /
  known risks summary so the next reader does not have to parse every slice.

Latest validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.

## Workout detection signal-language checkpoint - July 1, 2026

This pass aligns the live workout detection prompt and notification copy with
the review flow's user-facing source language. The card now describes strap
signal, time seen, and the next action, rather than using the more internal
`Capture` wording.

What changed:
- Inline workout detection decision chips now read `Signal`, `Time`, and `Next`.
- The ready state now says `Review`; the watching state says `Watching`.
- The detection accessibility label now says `Strap signal`.
- Workout review notifications now start with `Strap HR window...` so the source
  boundary is explicit outside the app too.
- Static checks now forbid `decisionChip(title: "Capture"` in the detection
  banner and require the strap-window notification body.

What did not change:
- No detector thresholds, notification cadence, review-worthy gates, workout
  saving behavior, sensor source policy, or Liquid Glass visual thesis changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-detection-ready`.
- Runtime visual check showed `Review this workout`, `Strap effort`, `Signal
  Ready`, `Time 16m`, `Next Review`, and the primary `Review workout` action.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-detection-signal-language.jpg`.

## Live workout animation-safety checkpoint - July 1, 2026

This pass starts the final performance/lag reduction track with a small,
targeted live workout fix. The HUD still keeps the energetic heart pulse in
normal mode, but the repeating symbol animation now respects Reduce Motion so
the live HR screen does less unnecessary animation work when users or the system
ask for calmer motion.

What changed:
- Added `@Environment(\.accessibilityReduceMotion)` to `AtriaLiveWorkoutView`.
- Moved the animated heart into `pulsingHeartIcon`.
- `pulsingHeartIcon` now renders a static heart when Reduce Motion is enabled
  and only applies `.symbolEffect(.pulse, options: .repeating)` otherwise.
- Static checks now require the Reduce Motion gate around the repeating heart
  animation.

What did not change:
- No live HR source, workout detector, strain target, zone calculation, workout
  saving, notification, or Liquid Glass visual thesis changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-fixture live-zone --atria-show-workout
  live-workout-target-hold`.
- Runtime visual check showed the Live workout HUD with HR 142, Hold here,
  Target lane, Strap HR source, Zone focus, and End workout intact.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-live-workout-reduce-motion-heart.jpg`.

## Sleep review stale-branch cleanup checkpoint - July 1, 2026

This pass removes unused sleep review helper branches that still carried older
`Captured` wording. The visible card already uses the newer Strap / Time / Save
path, so the cleanup reduces dead UI surface area and prevents accidentally
remounting the older, more diagnostic language later.

What changed:
- Removed unused `sleepReviewImpactStrip`.
- Removed unused `sleepReviewDecisionPulse`.
- Removed orphan helper functions `sleepImpactStep(...)` and
  `decisionPulseStep(...)`.
- Static checks now require the current `reviewProgressRail` path and forbid
  the removed stale helpers/phrasing.

What did not change:
- No sleep detection, nap/sleep classification, confirm/adjust/dismiss
  behavior, notification cadence, source policy, metric formulas, or Liquid
  Glass visual thesis changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Runtime visual check showed `Review last night`, `Confirm sleep`, `Adjust`,
  `Dismiss`, Strap / Time / Save, and the sleep night arc intact.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-stale-branch-cleanup.jpg`.

Research references:
- WHOOP Support - Viewing Trends: weekly, 1-month, and 6-month patterns across
  Strain, Recovery, Sleep, and Stress.
- WHOOP Support - Navigating the Mobile/Web App: Weekly, Monthly, and 6-Month
  trend switching.
- WHOOP app store / product copy: Sleep, Recovery, Strain, Stress, Behaviors,
  and weekly guidance are framed as daily action, not raw data.

Follow-up:
- Hubble's read-only scan identified the metric detail sheet as the next small
  insertion point for a similar visual period summary, using
  `AtriaDetailPeriodSummaryStrip` and existing day/week/month ranges.

## Sleep-review notification reminder checkpoint - July 1, 2026

The read-only sleep scan found that sleep-review notifications were one-shot per
candidate. If the user missed the first wake-up notification, later production
schedules skipped with `candidate_already_notified` while the sleep stayed
unconfirmed. This pass keeps the notification polite but no longer one-shot.

What changed:
- `LocalNotificationScheduler` now tracks sleep-review schedule count and last
  scheduled time per candidate id.
- A still-unresolved sleep review can be scheduled at most 2 times.
- The second schedule is gated by a 4-hour cooldown, so relaunches cannot spam
  the user.
- Dismissed candidates remain suppressed via `atria.sleepReview.dismissedID`.
- Once no unconfirmed candidate exists, the last-candidate marker is still
  cleared as before.

What did not change:
- No notification identifiers, titles, body copy, sleep detection thresholds,
  confirmation storage, or workout notification behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Static guards confirm sleep review no longer uses the old
  `candidate_already_notified` stop condition inside
  `makeSleepReviewDecision`, while workout notification behavior remains
  unchanged.

## History sleep-review CTA checkpoint - July 1, 2026

The read-only scan found that History showed sleep context as a chip/count, but
did not give users a direct way to confirm or adjust a pending sleep candidate.
This pass makes History actionable when a pending overnight review exists.

What changed:
- `HistoryView` now derives `pendingSleepReview` from
  `latestSleepReviewNightForUI(rest:source:)`.
- A new `HistorySleepReviewCTA` appears below the History hero when the latest
  sleep/nap review is unconfirmed.
- The CTA shows a compact progress ring, duration, time window, `Not counted` /
  `Separate`, and direct `Adjust` / `Confirm sleep` actions.
- Adjustment reuses `AtriaManualSleepSheet`; confirmation reuses
  `confirmSleepHistoryNightForUI`.
- Added a deterministic `history-sleep-review` debug fixture for visual checks.

What did not change:
- No sleep detection thresholds, daily rollup generation, notification cadence,
  confirmed sleep persistence format, or History row models changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-screen history --atria-ui-fixture history-sleep-review`.
- Runtime UI snapshot showed `History sleep review. 7h 18m,
  12:00 AM-7:18 AM, Not counted. Confirm or adjust.`, plus visible
  `Adjust` and `Confirm sleep`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-history-sleep-review-cta.jpg`.

## Sleep review wake-checkpoint checkpoint - July 1, 2026

The fresh overnight pull proved Atria captured the sleep window but left it in
`pending_user_confirmation`. This pass makes the first pending sleep card read
like a wake-up decision instead of another background metric card.

What changed:
- `AtriaSleepReviewCard` now shows a compact `wakeReviewCheckpoint` immediately
  after the pending-state header.
- The checkpoint uses a small progress ring, duration, time window, and
  `Not counted` / `Separate` state so the user sees the decision before the
  deeper review rails.
- Accessibility now exposes
  `Wake review checkpoint. \(night.durationText), \(startText) to \(endText), \(wakeCheckpointState).`

What did not change:
- No sleep detection thresholds, confirmation persistence, notification
  cadence, nap-vs-sleep classification, stage fabrication policy, or recovery
  counting behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-screen overview --atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`.
- Runtime UI snapshot showed `Wake review checkpoint. 7h 18m, 12:00 AM to
  7:18 AM, Not counted.`, plus the existing confirm/adjust review path.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-wake-checkpoint.jpg`.

Follow-up from read-only sleep-review scan:
- Pending sleep review is derived from `sleepHistorySnapshot` /
  `latestSleepReviewNightForUI`, while confirmed sleep is persisted separately.
- Home Today, Morning Journal, Vitals, and notifications surface review actions;
  History currently shows sleep context but no direct confirm/adjust CTA.
- Sleep-review notification is one-shot per candidate, so a missed notification
  can leave only the in-app cards as the reminder.

## Header live-zone source checkpoint - July 1, 2026

This pass makes the always-visible top HR-zone chip clearer without adding a
new surface. The chip already showed the zone ladder and zone code; it now also
shows the readable zone name plus an explicit live strap source cue.

What changed:
- `AtriaHeaderZoneIndicator` now renders `Z2 Endurance`-style zone text on the
  first line and `Live strap` on the second line.
- Accessibility now says
  `Heart rate zone \(zone.title), \(zone.name), live from strap.`
- The chip width cap moved to 72 points so the source cue fits without
  crowding the top action cluster.

What did not change:
- No HR-zone math, live HR sampling, workout detection, haptics, persistence,
  battery state logic, or data source behavior changed.

Validation:
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture live-zone`.
- Runtime UI snapshot showed `Z2 Endurance`, `Live strap`, and
  `Heart rate zone Zone 2, Endurance, live from strap.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-header-zone-live-source.jpg`.

## Sleep history stage-calibration rail checkpoint - July 1, 2026

This pass makes the sleep-history fallback more visual and less text-heavy.
When validated sleep-stage segments are not available, the glance card now shows
a muted staged rail with one compact label instead of listing every stage name.

What changed:
- Replaced the fallback `Stages building` plus `AWAKE/LIGHT/REM/SWS/DEEP`
  text row with `Stages calibrating` and a small color-coded stage rail.
- Added `fallbackStageHeight(_:)` so the calibration rail visually hints at a
  hypnogram shape without fabricating stage data.
- Kept the real `AtriaSleepMiniHypnogram` path unchanged when validated stage
  segments exist.

What did not change:
- No sleep detection, stage calculation, stage evidence gating, persistence,
  HealthKit export, or nap-vs-main-sleep behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Search confirmed the old fallback stage label row is gone from
  `AtriaOverviewSections.swift` and static guards.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture nap-only-morning`.
- Runtime UI snapshot showed `Sleep history`, `Nap · saved separate`, morning
  status `Wear` / `Sync` / `Review`, and `Stages calibrating`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-history-stage-calibration-rail.jpg`.

## Workout exercise selection path checkpoint - July 1, 2026

This pass makes the exercise-selection step feel more guided without adding
more catalog text. Users now see the intended flow before the search box and
large exercise catalog.

What changed:
- Added `exerciseSelectionPath` to the workout review Exercises step.
- The path shows `Suggested`, `Search`, and `Skip` as compact visual choices.
- Accessibility summarizes the path as: start with suggested movements, search
  any movement, or skip if unsure.

What did not change:
- No workout detection, exercise catalog contents, save schema, selected
  exercise behavior, or footer actions changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-review-flow --atria-workout-review-exercises-step`.
- Runtime UI snapshot showed `Exercise selection path. Start with suggested
  movements, search any movement, or skip if unsure.`, visible `Suggested`,
  `Search`, `Skip`, and visible `Back` / `Continue` footer actions.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-exercise-selection-path.jpg`.

## Workout exercise search-gated catalog checkpoint - July 1, 2026

This pass stops the Exercises step from dumping the full movement catalog before
the user asks for it. The default state now leads with suggestions and keeps the
full catalog behind search.

What changed:
- When exercise search is empty, the step shows quick-add suggestions and a
  compact `Full catalog waits behind search` preview card.
- The full grouped exercise grid now renders only after the user types into
  search.
- The preview card keeps the breadth visible by showing the catalog group
  count.

What did not change:
- No exercise catalog contents, selected-exercise behavior, workout save
  schema, workout detection, or footer actions changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture workout-review-flow --atria-workout-review-exercises-step`.
- Runtime UI snapshot showed quick-add suggestions, visible `Back` /
  `Continue`, and `Full exercise catalog waits behind search. 14 groups ready
  when needed.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-exercise-search-gated-catalog.jpg`.

## Overnight sleep review state checkpoint - July 1, 2026

Fresh cabled-iPhone pull after Aman woke up showed that Atria captured the
overnight strap-HR window but had not saved it as a confirmed sleep. That is the
right recovery-safety default, but the state needed to be product-readable:
pending sleep review, not an internal IMU blocker.

Device evidence:
- Pull artifact:
  `artifacts/device-sleep-wakeup-20260701-095551-after-review-state/pull-summary.txt`.
- Atria process was running on the physical iPhone.
- Strap battery was live from `2A19`: `67%`, `notCharging`.
- Confirmed sleep records were still `5`; latest confirmed sleep was the old
  `2026-06-30 09:04:02 IST` to `09:25:25 IST` nap.
- The detected overnight candidate was
  `2026-07-01 00:33:01 IST` to `08:46:29 IST`, duration `29608s`,
  `30773` HR samples, `23697` RR values, average HR `64`.
- The pull now reports
  `pending_sleep_review_status=pending_user_confirmation`,
  `pending_sleep_review_kind=sleep`,
  `pending_sleep_review_source=sleep_window`, and
  `pending_sleep_review_motion_policy=strap_hr_review_without_stage_fabrication`.

What changed:
- `SessionStore` now ranks long overnight strap-only main-sleep candidates above
  generic low-confidence candidates for review.
- Sleep evidence blockers now classify these windows as
  `sleep_review_pending_user_confirmation` instead of a motion-validation
  failure.
- `pull_atria_state.sh` now reports pending sleep review fields separately from
  confirmed sleep fields, so future morning checks can answer “captured,
  pending review, or confirmed” directly.

What did not change:
- Atria still does not silently confirm an HR-only overnight as final sleep.
- Sleep stages are not fabricated; pending/confirmed HR-only sleep remains
  clearly labeled for user review before recovery use.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Non-disruptive physical iPhone pull passed and showed the new pending review
  fields against the real overnight data.

## Sleep review pending-state header checkpoint - July 1, 2026

This pass makes the pending sleep-review state visible in the card itself, not
just in logs/pull summaries. The card now states that the detected overnight
window is pending review and not counted yet until the user confirms or adjusts.

What changed:
- `AtriaSleepReviewCard` now has a compact Liquid Glass state header.
- The header shows `Pending sleep review` / `Pending nap review` and
  `Not counted yet` / `Not merged`.
- The accessibility label combines the state as:
  `Pending sleep review. Not counted yet until you confirm or adjust.`

What did not change:
- No sleep detection, confirmation, persistence, recovery, or stage logic
  changed in this pass.
- The card still keeps `Confirm sleep`, `Adjust`, and `Not me` visible.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`.
- Runtime UI snapshot showed `Pending sleep review`, `Not counted yet`,
  `Review last night's sleep`, `Strap HR`, and visible `Confirm sleep`,
  `Adjust`, `Not me` actions.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-pending-state-header.jpg`.

## Workout review label-overlay checkpoint - July 1, 2026

This pass makes saved workout review false positives less scary. The card now
explains the WHOOP-style product model visually: the strap HR stays in the day,
the workout label is pending, and dismissing removes only the label.

Research note:
- Current WHOOP support/search snippets describe automatic activity detection as
  based on elevated HR, movement patterns, and strain levels, with activities
  logged after the effort. WHOOP community discussion also frames auto-detected
  activities as labels/overlays on continuous HR/strain data rather than the raw
  data itself. Atria now reflects that distinction in the review card.

What changed:
- Added `workoutInterpretationStrip` to `AtriaSavedWorkoutReviewBanner`.
- The strip shows compact chips: `HR kept / Daily strain`,
  `Label / Pending`, and `Dismiss / Label only`.
- Removed the redundant banner-level `Window / Type / Exercises` path row so
  `Review & label` and `Not a workout` remain visible on the first screen. The
  full guided path still exists inside the review flow.

What did not change:
- No workout detection thresholds, save schema, confirmation flow, or exercise
  selection behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture saved-workout-review`.
- Runtime UI snapshot showed `HR kept`, `Label`, `Dismiss`,
  `Daily strain`, `Pending`, `Label only`, plus visible `Review & label` and
  `Not a workout` actions.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-label-overlay-strip.jpg`.

## Trends action rail checkpoint - July 1, 2026

This pass makes the trend action readout more glanceable. The existing sentence
guidance remains, but the card now adds a compact visual rail for direction,
signal, and next move.

What changed:
- `AtriaTrendActionReadoutCard` now stacks the existing headline/detail with an
  `actionRail`.
- The rail shows `Direction`, `Signal`, and `Next` chips.
- Derived chip values stay compact: direction is `Rising` / `Dropping` /
  `Steady`; signal is `Support` / `Pressure` / `Stable`; next is `Build` /
  `Ease` / `Hold`.
- Accessibility now includes the same compact state:
  `Direction ... signal ... next ...`.

What did not change:
- No trend calculations, metric ranges, persistence, or chart data preparation
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot showed the Trends fixture, Day/Week/Month/3M/6M range
  controls, saved-point bars, and the period hero. The new action rail sits
  lower in the same card; source/static checks and the successful simulator
  build verify it.
- Visual evidence for the Trends fixture/range context:
  `artifacts/visual-checks/simulator/20260701-trends-action-rail-range-context.jpg`.

## Journal morning path rail checkpoint - July 1, 2026

This pass makes the Journal morning card read as a simple flow instead of
separate blocks. Users now see how sleep review, daily tags, and impact learning
connect.

What changed:
- Added `morningJournalPathRail` to `AtriaOverviewMorningJournalCard`.
- The rail uses compact chips: `Sleep`, `Tags`, and `Impact`.
- Values adapt to the current state: sleep shows `Review` or `Saved`, tags show
  `Today` or the selected count, and impact shows `Unlock` or `Learning`.
- Accessibility summarizes the flow as:
  `Morning journal path: review sleep, tag today, learn impact.`

What did not change:
- No journal persistence, behavior correlations, sleep confirmation, or tag
  behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment journal --atria-ui-fixture journal-impact`.
- Runtime UI snapshot showed `Morning journal path: review sleep, tag today,
  learn impact.`, visible `Sleep / Review`, `Tags / Today`, and
  `Impact / Unlock`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-journal-morning-path-rail.jpg`.

## Review notification copy checkpoint - July 1, 2026

This pass aligns local notification wording with the review model proven by the
fresh physical-iPhone morning pull: overnight strap HR can be captured and
reviewable without being silently counted as confirmed sleep.

What changed:
- Sleep-review notification copy now says `Confirm or adjust before it counts.`
  instead of implying recovery is already unlocked.
- Workout-review notification copy now matches the label-overlay model:
  `HR stays in your day. Label or dismiss.` for stronger workout candidates, and
  `Review the window. Label or dismiss.` for lighter effort candidates.
- Static guardrails now forbid the old `unlocks recovery` phrasing in the
  notification scheduler.

What did not change:
- No scheduling thresholds, candidate selection, storage, sleep scoring, workout
  detection, or visible UI surfaces changed.

Validation:
- Fresh physical-iPhone pull:
  `artifacts/device-sleep-wakeup-20260701-101023-fresh-morning-check/pull-summary.txt`.
- The pull showed `pending_sleep_review_status=pending_user_confirmation` for
  the `2026-07-01 00:33:01` to `08:46:29 IST` overnight strap-HR window, while
  the latest confirmed sleep record was still the older `2026-06-30 09:04` nap.
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.

## Sleep review progress rail checkpoint - July 1, 2026

This pass makes the pending overnight state feel like a morning product flow
instead of a diagnostic card. Current WHOOP public support still treats automatic
sleep/activity detection plus manual correction as first-class user paths; Atria
now mirrors that model visually with a compact `Captured -> Adjust -> Count`
rail on the sleep review card.

What changed:
- `AtriaSleepReviewCard` now shows `reviewProgressRail` immediately after the
  header: step 1 `Captured` from strap HR, step 2 `Adjust` with the time window,
  and step 3 `Count` / `Pending` for main sleep or `Save nap` / `Separate` for
  nap evidence.
- The rail carries the important state visually, so the card does not need more
  explanatory copy.
- Removed the `sparkle.magnifyingglass` SF Symbol from the sleep review state
  header and replaced it with `clock.badge.checkmark`, keeping the hard
  no-sparkles requirement intact.
- Removed the older `reviewTimeline` / `reviewPill` treatment that used a flat
  white translucent fill, so the surface stays closer to the Native Liquid Glass
  card language.

What did not change:
- No sleep detection thresholds, sleep confirmation persistence, recovery math,
  notification scheduling, or device-data collection behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`.
- Runtime UI snapshot showed `Sleep review progress: captured from strap heart
  rate, adjustable window 12:00 AM to 7:18 AM, sleep not counted yet.`, plus
  visible `Captured`, `Adjust`, `Count`, `Pending`, `Confirm sleep`, `Adjust`,
  and `Not me`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-progress-rail.jpg`.

## Workout review Now/Next rail checkpoint - July 1, 2026

This pass makes the guided workout review sheet easier to follow without adding
another paragraph. The flow already separates time, type, optional exercises,
and save; the new rail tells the user where they are and what comes next.

What changed:
- `AtriaWorkoutReviewFlow.stepIndicator` now includes a compact `stepContextRail`.
- The rail shows `Now`, the current step title, current index like `2/4`,
  `Next`, and the next step title.
- Label-only activity types still stay honest: the rail uses `Label only` when
  the selected type skips exercise selection.
- Accessibility now includes the same progress sentence:
  `Now Type, step 2 of 4. Next Exercises.`

What did not change:
- No workout detection gates, notification behavior, selected activity type,
  exercise catalog contents, save schema, HealthKit export, or persistence
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-fixture workout-review-flow --atria-workout-review-type-step`.
- Runtime UI snapshot showed `Workout review step Type. Now Type, step 2 of 4.
  Next Exercises.`, plus visible `Now`, `Type`, `2/4`, `Next`, `Exercises`,
  and `Guided`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-now-next-rail.jpg`.

## Trends period lens checkpoint - July 1, 2026

This pass makes the Trends surface easier to scan before the deeper chart/report
content. Current WHOOP public guidance still emphasizes weekly, monthly, and
6-month trend views from metric tiles; Atria now adds a compact period lens that
explains the selected window before the detailed period report.

What changed:
- `AtriaTrendChartCard` now shows `AtriaTrendPeriodLens` when a period readout
  has enough signal.
- The lens uses three compact chips: `Period`, `Cue`, and `Compare`.
- Prior-period state is explicit: `Compare` shows `Prior` when comparison data
  exists and `Building` while it is still learning.
- `AtriaTrendPeriodReadout` now exposes `hasPriorSignal` so the UI reads cached
  period state instead of deriving it inside view layout.
- The steady-period hero symbol no longer returns the banned `sparkles` SF
  Symbol; it now uses `scope`.

What did not change:
- No trend calculations, range filtering, chart data preparation, saved history,
  metric persistence, or y-axis scaling changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot showed `Trend period lens. Month. Cue Ready. Prior
  comparison ready.`, plus visible `Period`, `Month`, `Cue`, `Ready`,
  `Compare`, and `Prior`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-period-lens.jpg`.

## Journal impact evidence rail checkpoint - July 1, 2026

This pass makes behavior-impact insights feel more trustworthy without adding
more explanation. Current WHOOP Journal/Recovery Impact guidance emphasizes
behavior impact and sample-backed patterns; Atria now exposes a compact local
evidence rail before the impact map.

What changed:
- `AtriaJournalImpactStrip` now shows `impactEvidenceRail` whenever impact
  summaries are present.
- The rail uses three compact chips: `Logged`, `Signals`, and `Focus`.
- `Logged` shows local journal days, `Signals` shows how many summaries have an
  impact delta, and `Focus` shows the current strongest behavior signal.
- The Journal impact component now avoids local `Color.white.opacity` /
  `Color.black.opacity` fills in this source slice, using primary/tint opacity
  instead so the card stays closer to the Native Liquid Glass language.

What did not change:
- No behavior-correlation math, summary sorting, cached insight generation,
  journal persistence, tag behavior, cloud/network behavior, or render-path
  computation changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment journal --atria-ui-fixture journal-impact-focus`.
- Runtime UI snapshot showed `Journal evidence. 12 logged days. 3 behavior
  signals. Focus Sleep.`, plus visible `Logged`, `12d`, `Signals`, `3`,
  `Focus`, and `Sleep`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-journal-impact-evidence-rail.jpg`.

## Today's Plan balance rail checkpoint - July 1, 2026

This pass makes the top coaching card read as one connected decision instead of
three separate metrics. WHOOP's strongest home pattern is daily actionability:
recovery informs strain, and sleep closes the loop. Atria now makes that
relationship visible inside the existing `Today's Plan` card.

What changed:
- `AtriaOverviewGuidanceSection` now shows `planBalanceRail` between the sleep
  plan strip and the detail pills.
- The rail uses three compact chips: `Recovery`/`Baseline`, `Target`, and
  `Tonight`.
- The same row works while learning: baseline shows `Building`, target shows
  `Learning`, and tonight still shows the sleep-plan target.
- Accessibility summarizes the relationship as:
  `Plan balance. Baseline Building. Target strain Learning. Tonight Aim 8h.`

What did not change:
- No recovery math, strain target calculation, sleep planner calculation,
  baseline gating, notification behavior, persistence, or device-data collection
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`,
  then the scroll view was moved to the `Today's Plan` card.
- Runtime UI snapshot showed `Plan balance. Baseline Building. Target strain
  Learning. Tonight Aim 8h.`, plus visible `Baseline`, `Building`, `Target`,
  `Learning`, `Tonight`, and `8h`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-todays-plan-balance-rail.jpg`.

## Sleep review count-after-save trust checkpoint - July 1, 2026

This pass removes an over-promising phrase from the pending sleep review card.
The card already says sleep is `Not counted yet`; the impact strip now matches
that model instead of implying recovery is unlocked before confirmation.

What changed:
- `AtriaSleepReviewCard.sleepReviewImpactStrip` now uses `Count` /
  `After save` for main sleep evidence.
- Accessibility now says `count sleep after save` instead of `unlock recovery`.
- Static guardrails now reject `Unlocks` and `unlock recovery` inside the
  overview sleep-review source.

What did not change:
- No sleep detection thresholds, sleep confirmation persistence, recovery math,
  notification scheduling, review-card layout, or device-data collection changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`.
- Runtime UI snapshot showed `Sleep review impact: strap heart rate captured,
  review the window, then count sleep after save.`, plus visible `Count`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-count-after-save.jpg`.

## Saved workout capture-quality checkpoint - July 1, 2026

This pass fixes the saved workout review banner so fragmented strap-HR captures
are visible before the user opens the guided workout review. The detector
already computed stream coverage and gaps, but `WorkoutReviewCandidate` did not
carry that evidence to the home banner.

What changed:
- `WorkoutReviewCandidate` now carries `streamCoveragePercent`,
  `observedDuration`, `droppedGapSeconds`, `maxSampleGap`, and `gapCount`.
- `latestWorkoutReviewCandidate` threads the real replay summary coverage/gap
  evidence into the saved review candidate.
- `AtriaSavedWorkoutReviewBanner` now shows a compact `Capture quality` strip
  with recorded minutes, missing minutes, and sustained gap count/longest gap.
- The banner labels poor capture as `Fragmented` instead of over-confirming a
  workout when the strap-HR stream has gaps.
- The older duplicate Peak/Average/Signal pill row was removed so the card is
  less cramped on compact iPhone widths.

What did not change:
- No workout readiness thresholds, auto-detection gates, HR sampling logic,
  persistence, Health export, workout confirmation flow, or source policy
  changed. This is a data-threading and review-readability pass only.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture saved-workout-review`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-saved-workout-capture-quality.jpg`.

## Trends period-orbit checkpoint - July 1, 2026

This pass moves the Trends card closer to WHOOP's scan-first pattern: range
selection first, then a compact visual readout of the current period before the
deeper report cards. Current WHOOP surfaces emphasize top rings, range toggles,
and short period comparisons for Sleep, Recovery, and Strain; Atria keeps its
Native Liquid Glass look while adopting that faster visual hierarchy.

Research basis:
- WHOOP App Store / Play Store copy: daily Sleep, Recovery, Strain, Stress,
  behaviors, and coaching are the primary mental model.
- WHOOP support trend guidance: users inspect weekly, monthly, and longer
  patterns across Strain, Recovery, Sleep, and Stress.
- WHOOP current product imagery: top-level rings and trend range toggles are
  used to make period state scannable before details.

What changed:
- `AtriaTrendChartCard` now shows `AtriaTrendPeriodOrbit` after the range
  rhythm strip when enough period signal exists.
- The orbit renders three compact Liquid Glass mini-rings for `HRV`, `RHR`,
  and `Strain`, using existing period deltas and direction scoring.
- The previous visible `AtriaTrendPeriodLens` chip row was removed from the
  active Trends stack to reduce text density. The component remains defined for
  now because existing guardrails and future reuse still reference it.
- Accessibility summarizes the orbit as:
  `Trend period orbit for \(readout.rangeLabel). HRV ... RHR ... Strain ...`.

What did not change:
- No trend math, range cutoffs, saved-session collection, source policy,
  baseline logic, chart domain logic, or render-path caching changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-period-orbit.jpg`.

## Metric detail range-rhythm checkpoint - July 1, 2026

This pass extends the WHOOP-inspired range pattern from the main Trends card
into each metric detail sheet. Users who tap Recovery, HRV, RHR, Sleep, or
Strain now see a compact visual rhythm row before the deeper period report.

What changed:
- `AtriaMetricDetailSheet.metricChart` now shows `AtriaDetailRangeRhythmCard`
  whenever a period summary exists.
- The card reuses `AtriaDetailRangeDotStrip` and adds three compact anchors:
  current range (`Today`, `Week`, `Month`, `3M`, or `6M`), `Avg`, and
  `Vs prior`.
- The standalone dot strip remains only for sparse/no-summary states, avoiding
  duplicate pattern rows.
- Accessibility summarizes the component as:
  `Detail range rhythm. \(range.menuLabel). ... Average ... Versus prior ...`.

What did not change:
- No metric math, prepared-history caching, range cutoffs, chart domain logic,
  recovery contributor logic, sleep hypnogram, strain gauge, or data source
  behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture recovery-detail`.
- Runtime UI snapshot showed `Range rhythm`, `Month`, `Avg`, and `Vs prior`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-detail-range-rhythm.jpg`.

## Workout review notification capture-quality checkpoint - July 1, 2026

This pass aligns the workout review push notification with the in-app saved
workout review banner. If Atria asks about an effort after a fragmented strap-HR
capture, the notification now says that directly instead of sounding like a
clean workout confirmation.

What changed:
- `workoutReviewNotificationBody(for:)` now includes capture quality between
  the time window and the review action.
- `workoutReviewCaptureQualityText(for:)` maps saved candidate coverage/gaps to
  `Clean strap capture`, `Review strap gaps`, or `Fragmented strap capture`.
- The copy still keeps the key decision simple: label, adjust/review, or
  dismiss. HR remains in the day either way.

What did not change:
- No workout detection gates, push cadence, dismissal keys, notification
  identifiers, live-capture protection, scheduling cooldowns, Health export, or
  source policy changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture saved-workout-review`.
- Related visual evidence for the same capture-quality model:
  `artifacts/visual-checks/simulator/20260701-saved-workout-capture-quality.jpg`.

## Sleep review notification quality checkpoint - July 1, 2026

This pass wires the existing sleep-window quality helper into the sleep review
push copy. Morning notifications now tell the user whether Atria saw a
`Full night`, `Partial night`, `Sleep fragment`, `Clean nap`, or `Short nap`
before asking them to confirm or adjust.

What changed:
- `sleepReviewNotificationBody(for:)` now includes
  `sleepReviewWindowQuality(for:)` in all body shapes: start/end window,
  ending-only, and no-time fallback.
- The copy still preserves the review boundary: pending sleep must be confirmed
  or adjusted before it counts.

What did not change:
- No sleep detection thresholds, sleep confirmation logic, notification cadence,
  reminder limits, dismissal keys, source policy, stage estimation, or recovery
  math changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`.
- Related visual evidence for the same review model:
  `artifacts/visual-checks/simulator/20260701-sleep-review-wake-checkpoint.jpg`.

## Sleep review decision-pulse checkpoint - July 1, 2026

This pass makes the pending sleep review card less text-heavy and easier to
scan. The first visible decision path now reads as a compact visual pulse:
`HR` captured, `Window` editable, then `Save` counts the sleep after user
confirmation.

What changed:
- `AtriaSleepReviewCard` now places `sleepReviewDecisionPulse` in the primary
  review slot instead of the larger numbered progress rail.
- The pulse uses three connected Liquid Glass nodes and keeps the review
  boundary explicit: strap HR is captured, the window can be adjusted, and
  sleep only counts after save.
- The existing window-quality strip remains directly below, so `Full night`,
  `Partial night`, `Fragment`, `Clean nap`, or `Short nap` stays visible.

What did not change:
- No sleep detection logic, confirmation persistence, manual adjustment flow,
  notification cadence, recovery math, stage estimation, or source policy
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture pending-sleep-review`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-decision-pulse.jpg`.

## History day-sequence checkpoint - July 1, 2026

This pass makes the History daily-rollup card read more like a user-facing day
pattern instead of only a table of counts. The top rhythm still shows 14-day
strain, but a new compact `Day sequence` strip now marks sleep, saved workouts,
review-needed activity, recovery context, and quiet days before the detailed
rows.

What changed:
- `HistoryActivityRhythmCard` now includes `daySequenceStrip` between the
  14-day strain bars and the Saved/Review/Sleep summary pills.
- Each day renders as a compact visual node via `daySequenceNode(_:)`, using
  state from `sequenceState(for:)` so the user can scan the week without
  reading every rollup row.
- The strip calls out review-needed days visually, while keeping confirmed
  workouts, sleep context, and recovery context separate.

What did not change:
- No workout detection thresholds, sleep detection thresholds, saved-session
  persistence, source policy, rollup math, or confirmation flows changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-screen history --atria-ui-fixture history-activity-rhythm`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-history-day-sequence.jpg`.

## Trends range-confidence checkpoint - July 1, 2026

Research basis:
- Current WHOOP support material emphasizes comparing weekly, 1-month, and
  6-month trends across Strain, Recovery, Sleep, and Stress.
- Recent user discussion also points at a gap in month-to-month clarity when
  long-term summaries are too thin or too generic.

This pass turns Atria's existing D/W/M/3M/6M selector into a clearer visual
evidence surface. The range selector still controls the chart, but a new
`Range confidence` rail now shows how much saved signal backs each window
before the user reads the graph.

What changed:
- `AtriaTrendChartCard` now inserts `AtriaTrendRangeConfidenceRail` directly
  below the existing range rhythm strip.
- The rail reuses cached `rangeCoverage` counts and adds compact selectable
  nodes for D, W, M, 3M, and 6M.
- `AtriaTrendRange.confidenceTargetPoints` defines modest saved-point targets
  so windows read as `ready`, `building`, or `thin` without inventing another
  health score.
- Debug UI launches now ignore stale pending intent commands so simulator
  fixtures reliably open the requested screen for visual checks.

What did not change:
- No metric math, trend sampling, recovery/strain/HRV calculations, detection
  thresholds, persisted user data, or source policy changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-range-confidence.jpg`.

## Workout review route checkpoint - July 1, 2026

Superseded note:
- The route described in this checkpoint was removed by the later
  **Workout review footer-clearance checkpoint** because it peeked behind the
  Back/Continue dock on the Type step. Do not reintroduce
  `typeReviewRoute`, `typeRouteNode`, or `typeRouteConnector` unless the footer
  clearance issue is solved in a different layout.

Research basis:
- WHOOP activity detection is built around auto-detected elevated effort, then
  user review/edit when the start/end or label is wrong.
- User reports around WHOOP auto-type detection also reinforce that repeated
  behavior can make suggested labels useful, but the review moment still needs
  to let people correct the type.
- Strength-training references emphasize that strength work needs exercises,
  sets, reps, or at least movement labels to make strain/recovery more useful
  than a generic workout tag.

This pass improves Atria's workout confirmation flow at the exact point where
users choose what the detected effort was. The Type step now shows a compact
visual route: strap signal, selected activity type, then either Exercises or
Save depending on the activity family.

What changed:
- `AtriaWorkoutReviewFlow.typeStep` now includes `typeReviewRoute` between the
  suggested activity cards and the selected-type lens.
- The route uses `typeRouteNode` and `typeRouteConnector` to show the next
  branch visually instead of adding another paragraph of instructions.
- Strength/functional-style activities clearly continue into exercise
  selection, while label-only activities can proceed toward saving without
  forcing irrelevant exercise choices.

What did not change:
- No workout detection thresholds, confirmation persistence, exercise catalog
  contents, source policy, notification cadence, Health export, or strain math
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-fixture workout-review-flow
  --atria-workout-review-type-step`.
- UI automation scrolled the workout review sheet via `snapshot_ui` + `swipe`
  so the Type route was visible before capture.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-type-route.jpg`.

## Live HR zone header-pulse checkpoint - July 1, 2026

Superseded note:
- The top-chrome/header part of this checkpoint was removed by the later
  **Top chrome HR-zone rollback checkpoint**. HR-zone context should remain in
  the live heart-rate card and workout surfaces, not as a persistent top-bar
  chip.

This pass tightens the always-visible live heart-rate zone affordance. Atria
already showed zone context in the connected hero, top chrome, and live tab
accessory; this checkpoint makes the top chrome easier to scan when the hero is
partly scrolled away.

What changed:
- `AtriaHeaderZoneIndicator` now includes `headerZonePulseTrack`, a very thin
  six-segment visual track under the `Z2 Endurance` style label.
- The current zone segment is longer while prior/lower segments stay softly
  filled, so the user can read the zone shape before reading text.
- The change stays inside the existing Native Liquid Glass header capsule and
  reuses `Metrics.heartRateZoneTint(_:)`.

What did not change:
- No heart-rate zone math, workout detection logic, live sampling cadence,
  haptics, notifications, persistence, or source policy changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-fixture
  live-zone`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-live-zone-header-pulse.jpg`.

## Sleep review night-arc checkpoint - July 1, 2026

Research basis:
- WHOOP-style sleep flows auto-detect the sleep window, then let the user
  confirm or adjust the start/end before the night affects recovery.
- Morning review works best when the user can understand the night quickly:
  when it started, how long it lasted, when they woke, and whether it counts
  toward recovery.

This pass makes Atria's pending sleep card easier to scan before the user taps
Confirm or Adjust. It adds a compact `Night arc` visual that summarizes the
detected sleep window without fabricating sleep stages.

What changed:
- `AtriaSleepReviewCard` now includes `sleepReviewNightArc` between the main
  title/duration row and the existing decision pulse.
- The arc renders four beads: `Start`, `Window`, `Wake`, and `Impact`.
- `nightArcNode` and `nightArcConnector` keep the flow visual and compact,
  while the accessibility label states the same window explicitly.
- Debug UI launch routing now guards both pending-intent consume paths so
  simulator fixtures reliably open the requested screen instead of stale Data
  or capture intents.

What did not change:
- No sleep detection thresholds, confirmation persistence, manual adjustment
  flow, recovery math, stage estimation, notification cadence, or source policy
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- `snapshot_ui` confirmed the pending sleep review card exposed the new
  `Sleep review night arc` accessibility label before capture.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-night-arc.jpg`.

## Journal impact balance-rail checkpoint - July 1, 2026

This pass improves the Journal/Impacts surface so users can understand behavior
patterns before reading detailed correlation rows. The existing map, compass,
focus ring, and bars stay in place; a new compact balance rail now summarizes
what pulled recovery down versus what supported it.

What changed:
- `AtriaJournalImpactStrip` now inserts `AtriaJournalImpactBalanceRail` after
  the evidence chips and before the impact map.
- The balance rail splits the current summaries into `Watch` and `Support`
  sides using existing `impactDelta`/`impactMagnitude` values.
- The rail keeps the readout visual: two directional bars, a neutral center,
  signal counts, and a small lead label.

What did not change:
- No behavior-correlation math, journal persistence, insight sorting, recovery
  calculations, notification logic, or source policy changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment journal --atria-ui-fixture
  journal-impact-focus`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-journal-impact-balance-rail.jpg`.

## Today day-lane checkpoint - July 1, 2026

This pass makes Today's Plan more glanceable by turning the action cue into a
simple visual lane. Instead of only reading `Keep wearing today`, `Recover
first`, `Hold steady`, or `Room to push`, the user now sees where today sits on
a Recover -> Hold -> Push scale.

What changed:
- `AtriaOverviewGuidanceSection` now inserts `AtriaDayPlanLane` between the
  plan headline and the sleep plan strip.
- `dayLanePosition` maps existing guidance reasons to the lane without adding
  new readiness math.
- `dayLaneDetailText` keeps the lane label concise: `Recover`, `Ease`, `Hold`,
  `Push`, `Check`, or `Learning baseline`.
- `AtriaDayPlanLane` renders three visual segments and a marker using the
  existing readiness tint.

What did not change:
- No recovery calculation, strain target math, sleep planning, metric ordering,
  notification logic, persistence, or source policy changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture live-zone`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-today-day-lane.jpg`.

## Metric detail comparison-seesaw checkpoint - July 1, 2026

This pass makes metric detail sheets easier to scan when comparing the selected
range against the prior range. The existing range lens and range rhythm stay in
place; a new compact seesaw adds a visual `This vs prior` comparison directly
inside the range lens.

What changed:
- `AtriaDetailRangeLensCard` now inserts `AtriaDetailComparisonSeesaw` whenever
  a prior-window comparison exists.
- The seesaw reuses existing `AtriaDetailComparisonSummary.currentShare` and
  `priorShare`, so it adds no new metric math.
- The visual shows `Prior` on the left, `This` on the right, and the delta at
  the top, helping users understand range movement before reading the chart.

What did not change:
- No recovery, HRV, RHR, sleep, or strain calculations changed. No persistence,
  notification logic, source policy, chart sampling, or target logic changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-ui-overview-segment today --atria-ui-fixture recovery-detail`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-detail-comparison-seesaw.jpg`.

## Live workout target-lane checkpoint - July 1, 2026

This pass makes the active workout screen more glanceable in the WHOOP-style
moment where the user needs to know whether to build, hold, or ease off. The
existing live HR zone, target strain, and coach cue remain; a compact target
lane now fuses them into one visual readout.

What changed:
- `AtriaLiveWorkoutView` now inserts `workoutTargetLane(zone)` directly below
  the coach cue.
- The lane shows six HR-zone segments, highlights the current zone, and moves a
  marker along the rail using existing `strainTargetProgress`.
- The lane keeps text minimal with three chips: `Zone`, `Strain`, and `Target`.
- The view continues to use `atriaWorkoutGlassSurface` for Native Liquid Glass
  alignment and keeps the stop button isolated at the bottom.

What did not change:
- No workout detection, strain math, HR-zone thresholds, persistence,
  notification logic, source policy, or strap data pipeline changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-show-workout
  live-workout-target-build live-zone`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-live-workout-target-lane.jpg`.

## Top chrome HR-zone rollback checkpoint - July 1, 2026

User feedback: the app should not show the HR-zone chip in the top bar. The
zone readout belongs in live heart-rate and workout surfaces, not the persistent
top chrome.

What changed:
- Removed `AtriaHeaderZoneIndicator` from `AtriaHomeTopChrome`.
- Deleted the dedicated top-chrome zone indicator implementation.
- Added static guards so `AtriaHeaderZoneIndicator` cannot be reintroduced
  silently.
- Kept the existing live heart-rate card and live workout HR-zone surfaces.

What did not change:
- No HR-zone math, live HR source policy, strap data pipeline, workout screen,
  notification logic, or persistence changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture live-zone`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-top-chrome-zone-removed.jpg`.

## Trends range-dock simplification checkpoint - July 1, 2026

This pass removes duplicate range controls from Trends. The previous Trends top
stack showed the range picker, then a D/W/M/3M/6M rhythm strip, then another
D/W/M/3M/6M confidence rail. That made the first viewport feel busy before the
user reached the actual trend summary.

What changed:
- Replaced `AtriaTrendRangeRhythmStrip` and
  `AtriaTrendRangeConfidenceRail` with one `AtriaTrendRangeDock`.
- The dock keeps the same selectable D/W/M/3M/6M targets, saved-point counts,
  and readiness text, but compresses them into one Liquid Glass row.
- Added static guards so the old duplicated rhythm/confidence panels do not
  quietly return.

What did not change:
- No trend calculations, range cutoffs, metric summaries, chart scaling,
  period readout math, data source policy, or persistence changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Before visual reference:
  `artifacts/visual-checks/simulator/20260701-trends-before-simplification.jpg`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-range-dock.jpg`.

## Workout review focused-step checkpoint - July 1, 2026

This pass trims the guided workout-review sheet after visual inspection showed
the Type step was spending the first viewport on capture evidence instead of
the actual type choices. The heavy evidence readout is useful for deciding
whether the detected window is real, but it should not crowd every later step.

What changed:
- `AtriaWorkoutReviewFlow.header` now shows the zone evidence strip,
  `captureEvidenceStrip`, and `reviewDecisionLens` only on the Time step.
- Type, Exercises, and Summary keep the compact header chips, step rail, and
  step-specific content.
- This brings suggested workout types into the first Type-step viewport.

What did not change:
- No workout detection gates, saved-workout confirmation, exercise catalog,
  notification logic, Health export, source policy, or strap HR pipeline
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-fixture workout-review-flow
  --atria-workout-review-type-step`.
- Before visual reference:
  `artifacts/visual-checks/simulator/20260701-workout-review-type-before-trim.jpg`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-type-focused.jpg`.

## Workout review footer-clearance checkpoint - July 1, 2026

Follow-up visual inspection showed the Type step still had a decorative
`Signal -> Type -> Exercises` route peeking behind the bottom Back/Continue
dock. That violated the product rule that nothing should sit behind the primary
footer actions.

What changed:
- Removed `typeReviewRoute` from the Type step.
- Deleted the unused `typeRouteNode` and `typeRouteConnector` helpers.
- Added static guards so the removed route does not return to the Type step.
- The Type step now prioritizes suggested types and the selected type lens above
  the footer.

What did not change:
- No workout detection, save flow, exercise catalog, step navigation,
  notification logic, source policy, or strap HR pipeline changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-fixture workout-review-flow
  --atria-workout-review-type-step`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-type-footer-clear.jpg`.

## Workout save receipt memory checkpoint - July 1, 2026

This pass continues the WHOOP-inspired workout review direction: detection should
feel like a receipt the user can accept or correct, then Atria should clearly
remember the corrected label for future detection.

Current reference points:
- WHOOP's Activity & Sleep Auto-Detection support says workouts and sleep should
  be tracked without manual input, but the app still gives users a chance to
  review/edit activity records.
- WHOOP's activity auto-detection write-up describes waiting until HR returns to
  normal before logging an activity and highlights the semantic problem of
  deciding whether elevated HR is truly a workout.
- WHOOP trend/detail references keep the primary experience summary-first, with
  deeper data in fixed time ranges rather than a raw dashboard.

What changed:
- `AtriaWorkoutReviewFlow.summaryStep` now says `Check what gets remembered.`
  instead of another explanatory sentence.
- The final receipt's Time tile shows the actual start-end window instead of the
  vague `Adjusted` label.
- Added a compact `Save / History / Learn` rail so the user sees that saving
  creates a workout history item and feeds future label learning.
- The final receipt accessibility label now says Atria will save to history and
  learn from the selected label, while still naming strap HR as the source.

What did not change:
- No workout detection thresholds, auto-save semantics, exercise catalog,
  selected-exercise persistence, source policy, HealthKit export, or
  notification cadence changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen overview
  --atria-ui-fixture workout-review-flow --atria-workout-review-summary-step`.
- Runtime UI snapshot showed `Check what gets remembered.`, the exact window
  `2:32 PM-3:14 PM`, and the `Save`, `History`, `Learn` rail.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-summary-remembered-receipt.jpg`.

## Recovery notification action-copy checkpoint - July 1, 2026

This pass removes developer-facing confidence language from the recovery push
body. Notifications should help the user act quickly, not expose internal model
state.

What changed:
- `LocalNotificationScheduler.recoveryNotificationBody` now says:
  `Recovery is X% today. ... Use it to choose whether to push, hold, or recover.`
- The visible notification body no longer includes `Confidence: ...`.
- The helper no longer accepts a confidence parameter; confidence remains only in
  the internal schedule `reason` for diagnostics.
- Static guards now require the action-oriented copy and forbid the old visible
  `Confidence:` phrase.

What did not change:
- No recovery calculation, notification cadence, notification identifiers,
  authorization handling, sleep/workout review notifications, strain target
  notifications, source policy, or diagnostic reason logging changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-schedule-notifications --atria-notification-delay 3`.
- XcodeBuildMCP runtime log:
  `/Users/amanpandey/Library/Developer/XcodeBuildMCP/workspaces/atria-60f9d3687ed1/logs/com.adidshaft.atria_2026-07-01T09-47-30-049Z_helperpid86090_ownerpid90791_10298ada.log`
  showed notification scheduling still ran. Recovery itself skipped on simulator
  with `notification_skip kind=recovery reason=learning:_need_resting_HR`, so the
  exact recovery push was verified by source/static guard rather than delivered
  visually.

## Trends range-dock language checkpoint - July 1, 2026

This pass removes one more developer-style label from the active Overview Trends
surface. The range dock used to describe period coverage as `saved points`,
which is accurate internally but less natural for users scanning day/week/month
history.

What changed:
- `AtriaTrendRangeDock.selectedReadinessText` now reads like `31 days · ready`
  instead of `31 saved · ready`.
- Range buttons now expose accessibility labels like `Month trend range, 31
  days, ready` instead of `saved points`.
- Static guards forbid the old `saved points` and `saved ·` wording in the
  active trend chart.
- The older, currently-unused `AtriaOverviewTrendSection` summary card also uses
  `Direction` and `Privacy` chips instead of visible `Confidence` and `Source`
  chips, but the visual proof below is for the active chart surface.

What did not change:
- No trend math, range counts, chart sampling, range options, source policy,
  notification behavior, or persistence changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen overview
  --atria-ui-overview-segment trends --atria-ui-fixture trend-prior-comparison`.
- Runtime UI snapshot showed `31 days · ready` and accessibility targets like
  `Month trend range, 31 days, ready`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-days-ready-range-dock.jpg`.

## Saved workout signal checkpoint - July 1, 2026

This pass tightens the post-detection workout review card. The card used to
surface capture/coverage language in the decision strip and accessibility label,
which made the prompt feel like a stream-quality diagnostic instead of a user
decision.

What changed:
- `AtriaSavedWorkoutReviewBanner` now shows `Signal` instead of `Capture`.
- The visible signal state maps internal coverage/gap evidence to human labels:
  `Enough`, `Check`, or `Patchy`.
- The banner accessibility label no longer exposes stream coverage percentage,
  observed minutes, or missing minutes. It now says to review and label before
  saving.
- Static guards forbid the old saved-workout banner `captureQuality*` names,
  `Capture ... percent`, `minutes missing`, and `title: "Capture"` wording.

What did not change:
- No workout detection thresholds, review gating, coverage/gap math, candidate
  persistence, notification behavior, source policy, exercise flow, or HealthKit
  export changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen overview
  --atria-ui-overview-segment today --atria-ui-fixture saved-workout-review`.
- Runtime UI snapshot showed `Workout checkpoint. Decide now, signal Patchy,
  and Atria learns for next time.`, plus visible `Signal` / `Patchy`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-saved-workout-signal-checkpoint.jpg`.

## Live workout detection signal checkpoint - July 1, 2026

This pass applies the same user-first wording to the live workout-detection card.
The active prompt still used `High confidence`, `Status`, and `minutes observed`
language, which sounds like telemetry rather than a clear decision.

What changed:
- `AtriaWorkoutDetectionPrompt.confidenceLabel` now maps the high-sample state to
  `Strong signal` instead of `High confidence`.
- `AtriaWorkoutDetectionBanner.workoutDecisionStrip` now uses `Signal / Seen /
  Next` instead of `Status / Window / Next`.
- The workout-detection accessibility label now says `minutes seen` instead of
  `minutes observed`.
- Static guards forbid the old `High confidence` and `minutes observed` wording.

What did not change:
- No workout detection thresholds, review readiness gates, sample counting,
  strain math, source policy, saved review flow, notifications, or HealthKit
  export changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen overview
  --atria-ui-overview-segment today --atria-ui-fixture workout-detection`.
- Runtime UI snapshot showed `Workout checkpoint. Likely, 7 minutes seen, Keep
  wearing.`, plus visible `Signal`, `Seen`, `Next`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-detection-signal-seen.jpg`.

## Workout review header decision-copy checkpoint - July 1, 2026

This pass trims the active workout review sheet header so the user sees the next
job immediately. The previous subtitle was friendly but abstract:
`Confirm what happened, then Atria learns.`

What changed:
- `AtriaWorkoutReviewFlow.header` now says `Check time, type, then save.`
- Static guards prevent the old abstract subtitle from returning.
- Source-only cleanup also changed the currently-unused `captureEvidenceStrip`
  wording from `Capture check / Obs / Evidence` to `Review check / Seen / Later`,
  but that helper is not rendered in the current flow and is not counted as the
  visual proof for this pass.

What did not change:
- No workout detection thresholds, review navigation, time/type/exercise save
  behavior, source policy, notification behavior, HealthKit export, or footer
  layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen overview
  --atria-ui-overview-segment today --atria-ui-fixture workout-review-flow`.
- Runtime UI snapshot showed visible `Workout found` with `Check time, type,
  then save.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-header-check-time-type-save.jpg`.

## Sleep sync card wording checkpoint - July 1, 2026

This pass removes one internal label from the active sleep-sync card. The card
was already user-facing overall, but the first step still said `Backfill`, which
is implementation language. Users need to know they should sync.

What changed:
- `AtriaSleepSyncNeededCard` now shows `Sync / Ready` instead of
  `Backfill / Ready` when missed strap data needs to be pulled before sleep
  review can appear.
- Static guards now require the sleep-sync card to use `Sync`.

What did not change:
- No historical sync logic, backfill scheduling, live-capture protection,
  sleep detection, review gating, notification behavior, or source policy
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen overview
  --atria-ui-overview-segment today --atria-ui-fixture sleep-sync-needed`.
- Runtime UI snapshot showed `Sync sleep data`, `Sync`, `Ready`, `Sleep`,
  `Waiting`, `Review`, and `If found`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-sync-card-sync-ready.jpg`.

Follow-up resolved:
- The separate missed-data banner above this card was cleaned in the following
  checkpoint and now says `Sync ready`.

## Missed data sync-ready banner checkpoint - July 1, 2026

This pass completes the reachable sync wording cleanup started by the sleep-sync
card. The top missed-data banner still said `Backfill ready` and mentioned a
`gap marker`; both are implementation concepts.

What changed:
- `AtriaMissedDataBanner` now says `Sync ready`.
- The subtitle now says `Pull missed strap data when you are ready.`
- Static guards require the new copy and forbid `Backfill ready` / `gap marker`
  within the banner component.

What did not change:
- No historical sync trigger, force-sync behavior, live-capture protection,
  dismissal behavior, notification behavior, source policy, or persistence
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen overview
  --atria-ui-overview-segment today --atria-ui-fixture sleep-sync-needed`.
- Runtime UI snapshot showed `Sync ready`, `Pull missed strap data when you are
  ready.`, and the `Sync` action.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-missed-data-sync-ready.jpg`.

## Today action-first ordering checkpoint - July 1, 2026

This pass makes the Today first viewport prioritize the user's morning decision.
Visual inspection showed pending sleep review was appearing after backfill and
Bluetooth/system banners, which made the review feel secondary even when sleep
was waiting for confirmation.

What changed:
- `overviewContent` now renders workout/saved-review prompts and
  `AtriaOverviewTabContent` before `AtriaMissedDataBanner` and
  `AtriaConnectionDiagnosisBanner`.
- Backfill and connection diagnosis banners still remain available below the
  action/review content.
- Static guards now enforce that the Overview content appears before the
  backfill and connection banners.

What did not change:
- No sleep detection, workout detection, backfill sync behavior, Bluetooth
  diagnosis behavior, notification logic, source policy, or persistence changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Before visual reference:
  `artifacts/visual-checks/simulator/20260701-today-before-action-first.jpg`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-today-action-first-sleep-review.jpg`.

## Today conditional ordering checkpoint - July 1, 2026

This pass refines the action-first ordering so it does not hide system recovery
when there is no review decision. Pending sleep/workout review still wins the
first viewport; otherwise backfill and connection banners can stay high because
they are the current action.

What changed:
- Added `hasPrimaryReviewAction`, `hasWorkoutReviewAction`, and
  `hasPendingSleepReviewAction` in `AtriaHomeView`.
- Moved backfill and connection banners into `overviewSystemBanners`.
- `overviewSystemBanners` renders before `AtriaOverviewTabContent` only when
  no primary review action exists.
- When a sleep/workout review exists, `overviewSystemBanners` renders below the
  review/Today content.

What did not change:
- No sleep detection, workout detection, backfill sync behavior, Bluetooth
  diagnosis behavior, notification logic, source policy, or persistence changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with both:
  `--atria-ui-fixture pending-sleep-review` and
  `--atria-ui-fixture daily-focus-rail`.
- Review-present visual evidence:
  `artifacts/visual-checks/simulator/20260701-today-conditional-review-first.jpg`.
- No-review visual evidence:
  `artifacts/visual-checks/simulator/20260701-today-conditional-system-first.jpg`.

## Sleep review actions-first checkpoint - July 1, 2026

This pass makes pending sleep review easier to consume with less effort. Visual
inspection showed the sleep review card still made users read several evidence
rails before reaching `Confirm sleep`, `Adjust`, or `Not me`, and the final
classification lens repeated information already present in the state header,
night arc, decision pulse, and window-quality strip.

What changed:
- Removed the duplicate `sleepReviewClassificationLens` and
  `sleepReviewLensChip` helpers from `AtriaSleepReviewCard`.
- Moved the sleep review action buttons directly after the main sleep summary,
  before the detailed evidence rails.
- Kept the visual explanation below the actions: night arc, HR/window/save
  pulse, and full-night quality strip.
- Added static guards so actions remain before detailed evidence rails and the
  removed duplicate lens does not return.

What did not change:
- No sleep detection, confirmation persistence, manual adjustment flow,
  notification cadence, recovery math, stage estimation, source policy, or
  backfill behavior changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-actions-first.jpg`.

## Workout checkpoint simplification - July 1, 2026

This pass follows the WHOOP-style product pattern from current app/support
references: top-level cards should give a glanceable metric story and one clear
next action, while deeper evidence stays behind review/detail screens. The
previous workout prompt and saved workout card were still too developer-facing:
they stacked path rails, likely-label hints, capture-quality diagnostics, and
gap counters before the user decision.

What changed:
- `AtriaWorkoutDetectionBanner` now shows one compact `workoutDecisionStrip`
  with `Status`, `Window`, and `Next` instead of separate review-path,
  watching-signal, likely-label, and detection-pill sections.
- `AtriaSavedWorkoutReviewBanner` now shows one compact
  `savedWorkoutDecisionStrip`: decide now, capture state, learn next time.
- Removed the unused saved capture-quality detail strip and metric chips from
  the visible card path.
- Added static guards to keep these banners as user-first checkpoints and stop
  the old developer-heavy rails from returning.

What did not change:
- No workout detection threshold, strap-only source policy, workout
  confirmation persistence, HealthKit export, notification behavior, or
  exercise review flow changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.

## Today plan learning-language checkpoint - July 1, 2026

This pass removes developer-facing "learning" language from the always-visible
Today Plan baseline state. The card should explain the next user action with
minimum effort while Atria is still forming recovery/strain baselines.

What changed:
- The recovery fallback title now reads `Baseline forming` instead of
  `Learning baseline`.
- The strain target fallback now reads `Target strain building`, with the compact
  target value `Building`.
- The baseline hint now says `Wear a few mornings to unlock targets.`
- The Day lane fallback mirrors `Baseline forming` so VoiceOver and visible copy
  agree.
- Static guards now prevent the old Today Plan strings from returning inside
  `AtriaOverviewGuidanceSection`.

What did not change:
- No recovery math, strain target calculation, sleep detection, workout
  detection, source policy, Bluetooth state, persistence, or notification logic
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  sleep-sync-needed`.
- Runtime UI snapshot showed `Today's plan. Baseline forming. Keep wearing
  today. Target strain building...`, visible `Wear a few mornings to unlock
  targets.`, Day lane `Baseline forming`, and plan balance `Target strain
  Building`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-today-plan-baseline-forming.jpg`.

## Workout prompt and notification trust-copy checkpoint - July 1, 2026

This pass tightens the workout detection language users see before confirming a
workout. The detector is still conservative, but the copy now explains what to
do without sounding like a debug failure.

What changed:
- The inline workout-detection prompt now says `Atria is waiting for a steadier
  strap rise.` instead of `Atria is waiting for stronger strap evidence.`
- The workout review notification fallback now says `Review the window before
  saving.` instead of `Some minutes are missing.`
- Static guards require the new copy and prevent the old failure-style language
  from returning.

What did not change:
- No workout detection thresholds, strap-only source policy, session capture,
  saved workout candidate logic, HealthKit export, exercise selection, or
  notification cadence changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-detection`.
- Runtime UI snapshot showed `Watching effort`,
  `Atria is waiting for a steadier strap rise.`, and the compact
  `Signal / Seen / Next` checkpoint.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-detection-steadier-rise.jpg`.

## Trends time-window language checkpoint - July 1, 2026

This pass makes the Trends range selector read like a time lens instead of a
confidence/debug state. The graph already had day/week/month/3M/6M controls and
visual progress bars; the visible status now tells users how much of the chosen
window is in view.

What changed:
- `AtriaTrendRangeDock` now shows `31 days in view`, `8 days forming`, or
  `1 day started` style copy instead of `ready`, `building`, or `thin`.
- Range node counts now show compact day labels like `31d`.
- `AtriaTrendRangeLens` now mirrors the same language with `31d in view`,
  `8d forming`, or `1d started`.
- Static guards require the new time-window labels and prevent the old range
  readiness helper from returning.

What did not change:
- No trend samples, range math, chart scaling, metric selection, summary math,
  saved-session data source, or Liquid Glass surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime UI snapshot showed `31 days in view`, range nodes `1d`, `8d`, `31d`,
  `70d`, and the range rail `31d in view`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-days-in-view-range-dock.jpg`.

## Sleep review path wording checkpoint - July 1, 2026

This pass makes the pending sleep review card easier to consume after waking.
The actions were already correctly placed first; the visual path below them now
uses user-facing labels instead of implementation-state wording.

What changed:
- The sleep review progress rail now reads `Signal / Time / Save` instead of
  `Captured / Adjust / Count`.
- The signal value now reads `Strap`.
- The save value now reads `Counts` for main sleep and `Separate` for naps.
- The accessibility path now says `strap signal, editable time... save sleep
  before it counts`.
- Static guards prevent the old active rail labels from returning.

What did not change:
- No sleep detection, nap-vs-sleep classification, confirmation persistence,
  adjustment sheet, recovery math, source policy, notification cadence, or
  stage estimation changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Runtime UI snapshot showed the action buttons first, then `Signal`, `Time`,
  `Save`, `Strap`, and `Counts`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-signal-time-save.jpg`.

## Workout review type receipt checkpoint - July 1, 2026

This pass removes a small but trust-eroding label from the guided workout review
header. Once the user is in the review flow, the activity label is something
they are choosing, not something Atria should keep calling `Likely`.

What changed:
- The workout review receipt tile now reads `Type` instead of `Likely`.
- The receipt accessibility label now says `Type Strength` style copy instead
  of `Likely type Strength`.
- Static guards require the `Type` receipt and prevent the old `Likely` receipt
  wording from returning.

What did not change:
- No workout detection, activity suggestions, exercise catalog, review steps,
  save behavior, HealthKit export, source policy, or notification logic changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-review-flow`.
- Runtime UI snapshot showed `Workout receipt. Time 42m. Peak 142. Type
  Strength.` and visible receipt tile `Type`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-type-receipt.jpg`.

## Trends day-pattern strip checkpoint - July 1, 2026

This pass keeps the lower Trends pattern strip aligned with the time-window
language used by the range dock. The strip is a visual day-by-day shape, so it
now reads as a day pattern instead of a saved-session/debug window.

What changed:
- `AtriaTrendSessionDotStrip` now shows `Day pattern` instead of
  `Window pattern`.
- The count now shows compact day copy like `28d` instead of `28 saved`.
- The accessibility label now says `Day pattern for Resting HR, 28 days in
  view.`
- Static guards prevent `Window pattern`, `saved`, and `saved sessions` from
  returning inside the active dot strip.

What did not change:
- No trend samples, range math, chart scaling, metric selection, summary math,
  saved-session source, or Liquid Glass surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime UI snapshot after scrolling showed `Day pattern` and `28d`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-day-pattern-strip.jpg`.

## Trends header days-in-view checkpoint - July 1, 2026

This pass removes the last active `saved sessions` wording from the main Trends
card so the visible header, range dock, range rail, chart accessibility, and day
pattern all describe the graph as days in view.

What changed:
- The Trends card subtitle now reads `Last 30 days · 31 days` instead of
  `Last 30 days · 31 sessions`.
- The chart accessibility base now reads `31 days in view` instead of
  `31 saved sessions`.
- Static guards prevent the old `prepared.series.count) sessions` header and
  `saved sessions` chart-card wording from returning.

What did not change:
- No trend samples, range math, chart scaling, metric selection, summary math,
  saved-session source, or Liquid Glass surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime UI snapshot showed `Last 30 days · 31 days` and `31 days in view`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-header-days-in-view.jpg`.

## Journal impact links checkpoint - July 1, 2026

This pass makes the Journal impact board read like behavior relationships
instead of model diagnostics. Users are trying to see what habits appear linked
to recovery/HRV, so the visible language now says links rather than signals.

What changed:
- The impact glance chip now reads `Links` instead of `Signals`.
- Watch/support lane counts now read `1 link` / `2 links` instead of
  `1 signal` / `2 signals`.
- Journal impact accessibility now says `behavior links`.
- Recovery balance accessibility now says watch/support `links`.
- Static guards prevent the old Journal impact `Signals` / `behavior signals`
  / `signal` count copy from returning.

What did not change:
- No behavior correlation math, tag collection, cached summaries, Journal flow,
  privacy/local-only policy, or Liquid Glass surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment journal --atria-ui-fixture
  journal-impact`.
- Runtime UI snapshot after scrolling showed `1 link`, `2 links`, and the
  `Links` chip.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-journal-impact-links.jpg`.

## Live accessory zone rollback checkpoint - July 1, 2026

This pass keeps the always-on live accessory focused on the two things users
need at a glance: strap recording and honest battery/charger state. Heart-rate
zones still matter, but they belong in the live heart-rate detail card and
workout surfaces rather than crowding persistent chrome.

What changed:
- Removed `AtriaLiveZoneAccessoryPill` from `AtriaLiveTabAccessory`.
- The live accessory now shows heart + strap battery + charger status only.
- The live accessory accessibility now says live strap battery/charger status
  without adding zone text.
- Static guards prevent the zone pill, `heartRateZone`, and zone accessibility
  copy from returning inside the live accessory.

What did not change:
- No HR-zone math, hero zone rail/lens, live workout zone target lane, strap
  data source, battery state logic, tab accessory placement, or Liquid Glass
  surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture live-zone`.
- Runtime UI snapshot showed persistent chrome `Connection Live` and
  `Strap battery 72%, Strap not charging.` while the live detail card still
  showed `Zone 2`, `Endurance`, and the heart-rate zone lens.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-live-accessory-no-zone.jpg`.

## Morning journal path checkpoint - July 1, 2026

This pass applies the same user-first framing to the morning Journal entry
point. Current WHOOP behavior patterns reinforce that auto-detected sleep and
activities should be shown as reviewable moments, and journal impacts should
feel like habit links rather than implementation state.

Research notes:
- WHOOP support describes Activity & Sleep Auto-Detection as a seamless way to
  track workouts and sleep, with review/edit expectations around detected
  windows.
- WHOOP's Recovery Impacts framing focuses on how daily behaviors, sleep, and
  strain influence recovery; users should see relationships, not model labels.
- User reports around activity detection emphasize editability: start/end time
  and activity type need to feel easy to correct.

What changed:
- The morning Journal rail now reads as a guided path: `Sleep`, `Tags`, `Links`.
- The third step now says `Links` with `Ready` / `Build` instead of
  `Impact` with `Local` / `Unlock`.
- The accessibility label now says `Morning path: review sleep, tag today, and
  see habit links.`
- Static guards prevent the old `Impact`, `Local`, `Unlock`,
  `Morning journal stack`, and `local impact learning` wording from returning
  inside the morning card.

What did not change:
- No journal tag storage, sleep confirmation, sleep adjustment, behavior
  correlation math, impact cards, privacy/local-only policy, or Liquid Glass
  surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment journal --atria-ui-fixture
  journal-impact`.
- Runtime UI snapshot showed `Morning path: review sleep, tag today, and see
  habit links.`, plus visible `Sleep`, `Tags`, `Links`, `Review`, `Today`, and
  `Build`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-morning-journal-path-links.jpg`.

## Saved workout review path checkpoint - July 1, 2026

This pass makes the saved workout review banner read like an editable WHOOP-like
activity review instead of a detector checkpoint. Users should see the next
action: review the detected window, check whether the strap capture was clean,
then label and save.

What changed:
- The saved workout decision strip now reads `Review / Strap / Save`.
- The strip values now read `Window`, the capture quality (`Enough`, `Check`,
  or `Patchy`), and `After label`.
- The accessibility label now says `Workout review path. Review the window,
  strap capture ..., then save after labeling.`
- Static guards prevent the old `Decide`, `Signal`, `Learn`, and
  `Atria learns for next time` wording from returning inside the saved workout
  banner.

What did not change:
- No workout detector thresholds, strap-only source policy, saved candidate
  stitching, coverage/gap math, review sheet steps, exercise catalog,
  notification logic, or Liquid Glass surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  saved-workout-review`.
- Runtime UI snapshot showed `Workout review path. Review the window, strap
  capture Patchy, then save after labeling.`, plus visible `Review`, `Window`,
  `Strap`, `Patchy`, `Save`, `After label`, `Review & label`, and
  `Not a workout`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-saved-workout-review-path.jpg`.

## Trends recovery-strain glance checkpoint - July 1, 2026

This pass makes the main Trends glance easier to read at a glance. The card was
already visual and compact, but the two big bars used model-ish labels
`Reserve` and `Load`. The same math now appears as `Recovery` and `Strain`, so
the top summary reads closer to what users expect from WHOOP-style recovery and
strain dashboards.

What changed:
- `AtriaTrendGlanceBoard` now labels the recovery bar `Recovery`.
- The strain/load-pressure bar now reads `Strain`.
- The trend glance accessibility label now says `Recovery ... percent, strain
  ... percent`.
- Static guards prevent `Reserve` / `Load` from returning inside the active
  trend glance board.

What did not change:
- No trend range math, HRV/RHR/strain deltas, period comparison, day/week/month
  controls, charts, samples, color palette, or Liquid Glass surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime UI snapshot showed `Trend glance. Strain-heavy month. Recover.
  Recovery 74 percent, strain 53 percent...`, plus visible `Recovery`,
  `Strain`, and the Day/Week/Month/3M/6M range controls.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-recovery-strain-glance.jpg`.

## Strap battery pending wording checkpoint - July 1, 2026

This pass fixes a small but trust-eroding display state found during visual
checks: when the strap battery level and charger state were both unknown, the
header could announce `Strap battery Waiting, Waiting.` The app now collapses
that into one clear pending state.

What changed:
- Unknown strap battery level now displays as `Pending` instead of `Waiting`.
- Unknown battery summary now reads `Battery pending`.
- Header/accessory accessibility now uses one canonical
  `batteryAccessibilityText`.
- Unknown battery accessibility now says `Strap battery pending.`
- Static guards prevent the old duplicated header accessibility construction
  and `Waiting` fallback from returning.

What did not change:
- No BLE battery reads, charger-state freshness, stale charging protection,
  notification logic, battery icons, or Liquid Glass chrome changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime UI snapshot showed `Strap battery pending.` instead of
  `Strap battery Waiting, Waiting.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-strap-battery-pending.jpg`.

## Sleep review counts arc checkpoint - July 1, 2026

This pass makes the pending sleep review arc answer the user's immediate
question: what happens if I save this detected window? The card already kept
Confirm/Adjust first; the night arc endpoint now uses count semantics instead
of abstract impact language.

What changed:
- `AtriaSleepReviewCard.sleepReviewNightArc` now labels the final node
  `Counts` instead of `Impact`.
- The final value remains `Recovery` for main sleep and `Separate` for naps.
- The sleep review night-arc accessibility label now says `counts ...`.
- Static guards prevent the old `Impact` node and `impact ...` accessibility
  phrasing from returning inside the night arc.

What did not change:
- No sleep detection, nap-vs-sleep classification, confirmation persistence,
  adjustment sheet, recovery math, notification logic, or Liquid Glass surface
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Runtime UI snapshot showed `Sleep review night arc. Start 12:00 AM, window
  7h 18m, wake 7:18 AM, counts Recovery.`, plus visible `Counts` and
  `Recovery`, with `Confirm sleep`, `Adjust`, and `Not me` still before the
  evidence rails.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-counts-arc.jpg`.

## Recovery balance wording checkpoint - July 1, 2026

This pass makes the Recovery detail contributor map read like a user explanation
instead of an internal signal model. The visual map still shows pressure versus
support around baseline, but the labels now talk about recovery factors.

What changed:
- The contributor map explainer now says `Factors to the right supported
  recovery; factors to the left pulled it down.`
- The compact balance strip now reads `Recovery balance` instead of
  `Signal balance`.
- The accessibility label now says `Recovery balance...`.
- Static guards prevent `Signals to the right`, `Signal balance`, and
  `Recovery signal balance` from returning inside the contributor map.

What did not change:
- No recovery math, contributor weights, pressure/support rails, colors,
  baseline logic, detail charts, or Liquid Glass surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  recovery-detail`.
- Runtime UI snapshot showed `Factors to the right supported recovery...` and
  `Recovery balance. Supported.` inside the Recovery detail sheet.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-recovery-balance-factors.jpg`.

## Research sensors wording checkpoint - July 1, 2026

This pass makes the Data tab research card read less like developer
instrumentation while keeping the safety caveats clear. The card still avoids
claiming validated SpO2, absolute body temperature, or HealthKit export for
research-only rows.

What changed:
- The card header now reads `Research sensors` instead of `Sensor signals`.
- The empty SpO2 footnote now says `Early reading; not a SpO2 value.`
- The info sheet footer now says `Research readings are local...`.
- Static guards prevent the old user-facing research wording from returning
  inside the research card/sheet.

What did not change:
- No BLE collection, WHOOP strap parsing, HealthKit writes, SpO2 validation,
  skin-temperature baseline math, strap step estimates, IMU audit behavior, or
  Liquid Glass surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  collection`.
- Runtime UI snapshot showed `Research sensors` and `Blood oxygen --,
  Learning, Early reading; not a SpO2 value.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-research-sensors-card.jpg`.

## Review notification copy checkpoint - July 1, 2026

This pass makes sleep and workout review notifications match the product flow
more closely: Atria detects a window, then the user reviews, adjusts, labels, or
dismisses. The notification copy is shorter and avoids implying Atria already
knows the workout type.

Current WHOOP research notes used for direction:
- WHOOP's support pages frame activity and sleep auto-detection as automatic
  detection plus user review/manual editing.
- WHOOP's activity list confirms activity type is a large user-facing taxonomy,
  so Atria should ask for type/label instead of guessing too aggressively.
- WHOOP's trends docs still emphasize fixed weekly, 1-month, and 6-month
  periods, supporting the existing drill-down approach instead of a graph tab.

What changed:
- Sleep review titles now read `Review your nap` or `Review last night's sleep`.
- Sleep review bodies now start with the detected duration/window and then ask
  the user to confirm or adjust timing.
- Workout review titles now read `Review this workout` or `Review this effort`.
- Workout review bodies now start with `Strap saw ...`, keeping the source
  boundary clear and avoiding phone-motion language.
- Static guards prevent the older `Check...`, `Atria found...`, `Log this
  workout?`, and `from your strap` notification copy from returning.

What did not change:
- No sleep/workout detection thresholds, reviewability gates, notification
  scheduling cooldowns, reminder limits, local-dismissal memory, BLE reads,
  HealthKit writes, workout type selection flow, or Liquid Glass UI changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding
  --atria-schedule-notifications --atria-notification-delay 1`.
- Runtime logs confirmed conservative scheduling with no fabricated review:
  `notification_skip kind=sleep_review reason=no_unconfirmed_sleep_candidate`
  and `notification_skip kind=workout_review
  reason=no_reviewable_workout_candidate`.
- Visual sanity screenshot from the launched build:
  `artifacts/visual-checks/simulator/20260701-notification-review-copy-build.jpg`.

## Trends recovery-care wording checkpoint - July 1, 2026

This pass makes the active Trends hero read more like a user-facing takeaway.
When HRV/RHR are moving against recovery, the card now says `Recovery needs
care` instead of the more diagnostic `Recovery pressure`.

What changed:
- `AtriaTrendPeriodReadout.title` now returns `Recovery needs care` for the
  recovery-pressure condition.
- The active Trends glance and legacy period hero both key their Protect cue and
  cyan tint off `Recovery needs care`.
- Added a DEBUG-only `trend-recovery-care` fixture so this exact state can be
  screenshot-verified without altering production data.
- Static guards prevent `Recovery pressure` from returning in the active Trends
  readout/glance source.

What did not change:
- No trend math, HRV/RHR/strain thresholds, production data, range controls,
  chart marks, cache behavior, workout/sleep detection, notifications, or
  Liquid Glass surface changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-recovery-care`.
- Runtime UI snapshot showed `Trend glance. Recovery needs care. Protect.
  Recovery 10 percent, strain 43 percent...`, plus the visible `Recovery needs
  care` title.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-recovery-needs-care.jpg`.

## Workout review strap-HR wording checkpoint - July 1, 2026

This pass tightens the guided workout review flow around the strap-only source
boundary. The review sheet already leads users through time, type, exercises,
and save; this change removes remaining user-facing `signal` wording from that
flow and uses strap HR/capture language instead.

What changed:
- The saved workout banner accessibility now says `Strap capture ...` instead
  of `Signal ...`.
- The workout type step now labels suggestions as `Suggested from strap HR`.
- The detection/review capture tiles now use `Capture` instead of `Signal`.
- The workout review header accessibility now says `Strap HR peak ...`.
- Static guards prevent the old workout-review `signal` phrases from returning
  inside the review/detection banner flow.

What did not change:
- No workout detector thresholds, reviewability rules, strap HR calculations,
  type suggestions, exercise catalog contents, save persistence, notification
  logic, HealthKit/CoreMotion policy, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-review-flow --atria-workout-review-type-step`.
- Runtime UI snapshot showed `Suggested from strap HR`, `Strap HR peak 142
  beats per minute`, and the guided `Type` step with `Strength`, `Cardio`, and
  `Functional` suggestions.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-strap-hr-type.jpg`.

## Workout hold capture wording checkpoint - July 1, 2026

This pass makes the conservative workout hold state easier to trust. When Atria
has possible effort but should not ask the user to label it yet, the banner now
talks about strap capture strength instead of internal `signal` wording.

What changed:
- The possible-effort hold title now reads `Possible effort saved`.
- The detail now says `No review prompt until strap capture is stronger.`
- The accessibility label now explains that strap capture looks like possible
  effort, not a strong workout.
- Static guards prevent `Workout signal held`, `until signal improves`, and
  `because the signal is possible effort` from returning inside the workout
  banner flow.

What did not change:
- No workout detector thresholds, prompt-worthiness rules, candidate storage,
  live HR settle threshold, notifications, review sheet flow, exercise catalog,
  HealthKit/CoreMotion policy, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-review-hold-possible`.
- Runtime UI snapshot showed `Possible effort saved`, `Strap HR`, `Saved as
  possible effort. No review prompt until strap capture is stronger.`, and the
  `Observe / Settle / Ask` path.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-hold-possible-capture.jpg`.

## Sleep sync action wording checkpoint - July 1, 2026

This pass makes the morning sleep-sync card read like a simple next action
instead of a conditional detector message. When missed strap data must be pulled
before sleep can be reviewed, the card now tells the user what happens next.

What changed:
- The card title now reads `Sync sleep data` instead of `Sleep sync needed`.
- The body now says `Pull missed strap data. If Atria finds sleep, review it
  next.`
- The review status pill now reads `If found` instead of `After sync`.
- Static guards prevent the old `Sleep sync needed`, `if a sleep window
  appears`, and `After sync` wording from returning inside the sleep-sync card.

What did not change:
- No range-loss backfill gating, live-stream protection, sleep detection,
  sleep/nap review, sync action, notifications, HealthKit/CoreMotion policy, or
  Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  sleep-sync-needed`.
- Runtime UI snapshot showed `Sync sleep data`, `Pull missed strap data. If
  Atria finds sleep, review it next.`, `Sync Ready`, `Sleep Waiting`, and
  `Review If found`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-sync-data-if-found.jpg`.

## Sleep review strap-HR rail checkpoint - July 1, 2026

This pass removes the last user-facing `signal` wording from the pending sleep
review progress rail. The review path now speaks in the same source-clear terms
as the workout review flow: strap heart rate, editable time, then save.

What changed:
- The first sleep-review progress step now reads `Strap` / `HR` instead of
  `Signal` / `Strap`.
- The progress rail accessibility label now says `strap heart rate`.
- Static guards prevent `title: "Signal"`, `value: "Strap"`, and
  `Sleep review path: strap signal` from returning inside the progress rail.

What did not change:
- No sleep/nap detection, sleep review gating, confirm/adjust/dismiss actions,
  recovery counting, sync/backfill behavior, notifications, or Liquid Glass
  layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Runtime UI snapshot showed `Sleep review path: strap heart rate...`, visible
  `Strap`, `HR`, `Time`, and `Save` steps, plus `Confirm sleep`, `Adjust`, and
  `Not me`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-strap-hr-rail.jpg`.

## Metric detail period copy checkpoint - July 1, 2026

This pass makes the metric-detail period report read less like an internal
debug panel. The graph/report card still uses the same compact Liquid Glass
structure, but the visible labels now tell the user what they are looking at
with less effort.

What changed:
- The detail report header now reads `This period` instead of `Period report`.
- The report chips now read `Latest`, `Change`, and `Compare` instead of
  `Now`, `Move`, and `Prior`.
- The accessibility label now says `This period. Latest..., change...,
  compared with prior..., average...`.
- Static guards now expect the clearer copy in the metric-detail report card.

What did not change:
- No live strap ingestion, sleep/workout detection, source policy,
  recovery/strain math, chart data preparation, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  recovery-detail`.
- Runtime UI snapshot verified the recovery detail/trend surface and range
  readouts. The edited report-card copy is guarded by static tests; the current
  visible fold showed the range lens and comparison cards above the lower
  report card.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-recovery-detail-this-period.jpg`.

## Trend snapshot wording checkpoint - July 1, 2026

This pass follows the current WHOOP trend-view direction: weekly/monthly/6-month
views should quickly answer what changed across Recovery, Strain, and Sleep
without making the user decode internal labels. Atria keeps its Native Liquid
Glass card, but the top range summary now reads like a user-facing snapshot.

What changed:
- The active metric-detail range card now says `Trend snapshot` instead of
  `Range lens`.
- The third stat now says `Change` instead of `Move`.
- The accessibility label now says `Trend snapshot ... change ...`.
- Static guards prevent the old `Range lens` / `Move` wording from returning
  inside `AtriaDetailRangeLensCard`.

Research note:
- WHOOP's current Trend Views page emphasizes weekly, monthly, and 6-month
  views for Sleep, Strain, and Recovery.
- WHOOP support describes trends as weekly, 1-month, and 6-month patterns
  across Strain, Recovery, Sleep, and Stress.
- WHOOP support also describes auto-detection as sustained elevated heart rate
  that is processed after the activity is finished, which supports Atria's
  direction of showing concise reviewable summaries rather than noisy raw
  detector language.

What did not change:
- No live strap ingestion, auto-detection thresholds, source policy,
  recovery/strain math, chart data preparation, notifications, or Liquid Glass
  layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  recovery-detail`.
- Runtime UI snapshot showed `Trend snapshot Month. Latest 62%, average 73%,
  change -18%.`, visible `Trend snapshot`, `Latest`, `Avg`, and `Change`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trend-snapshot-change.jpg`.

## Workout review window wording checkpoint - July 1, 2026

This pass makes the saved workout review prompt feel like a calm user decision
instead of a detector verdict. The card still leads with strap-HR evidence and
the same Liquid Glass rail, but the language now frames the time range as the
workout window the user can review.

What changed:
- The saved workout evidence rail now says `Workout window` instead of
  `Detected window`.
- The secondary action now says `Dismiss` instead of `Not a workout`.
- The accessibility label now says `Workout window ...` for the HR evidence
  rail.
- Static guards prevent the old `Detected window` and `Not a workout` wording
  from returning inside `AtriaSavedWorkoutReviewBanner`.

What did not change:
- No workout detector thresholds, live strap ingestion, source policy,
  exercise labeling flow, saved-session math, notification scheduling, or
  Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  saved-workout-review`.
- Runtime UI snapshot showed `Review & label`, `Dismiss`, `Workout window`,
  `3:23 PM-4:31 PM`, `Peak 156`, `Avg 118`, and `1h 8m from strap HR`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-window-dismiss.jpg`.

## Sleep review morning wording checkpoint - July 1, 2026

This pass makes the pending sleep review card feel like a calm morning task
instead of an app-owned detection verdict. The card still keeps the same visual
arc, strap-HR path, confirm/adjust/dismiss actions, and Native Liquid Glass
layout.

What changed:
- The pending sleep title now reads `Review your sleep` instead of `Atria found
  your sleep`; naps use `Review your nap`.
- The visible wake checkpoint now says `Review first` instead of `Not counted`
  for unconfirmed main sleep.
- Internal review-state copy now uses `Ready to review` and `Counts after save`
  instead of waiting/counting language.
- Static guards prevent `Atria found your sleep`, `Sleep waiting`,
  `Confirm to count`, and related detector-first copy from returning inside the
  sleep review card.

What did not change:
- No sleep/nap detection thresholds, sleep-vs-nap classification, confirmation
  save logic, recovery math, notifications, sync/backfill behavior, or Liquid
  Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Runtime UI snapshot showed `Review your sleep`, `Review first`, `Confirm
  sleep`, `Adjust`, `Not me`, `Strap HR`, `Time`, and `Save Counts`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-review-first.jpg`.

## Review notification wording checkpoint - July 1, 2026

This pass aligns local review notifications with the calmer in-app review cards.
The push should now prepare the user for a quick confirmation/edit moment rather
than sounding like raw detector output.

What changed:
- Sleep review notification title now uses `Review your sleep` for main sleep
  and `Review your nap` for naps.
- Sleep review notification bodies no longer say `detected`; they lead with the
  duration/window and then ask the user to confirm or adjust.
- Workout review notification bodies now start with `Workout window ...`
  instead of `Strap saw ...`.
- Static guards prevent `Review last night's sleep`, `\(night.durationText)
  detected`, and `Strap saw \(candidate.durationMinutes)m` from returning in
  review notification copy.

What did not change:
- No notification cadence, permission handling, scheduling identifiers,
  auto-detection thresholds, dismissal state, source policy, or Liquid Glass UI
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Targeted source verification showed the scheduler now contains
  `Review your sleep` and `Workout window ...`, with the old review notification
  wording only present as stale-copy test guards.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- No live local notification banner was captured in this pass; verification is
  source guardrails plus simulator build smoke test.

## Sleep review dismiss action checkpoint - July 1, 2026

This pass makes the pending sleep review action row match the calmer workout
review language. The user is deciding whether to save or ignore the reviewed
window; the button no longer says `Not me`.

What changed:
- The sleep/nap review secondary action now says `Dismiss` instead of `Not me`.
- The accessibility hint now says `Dismisses this review without saving it.`
- The host comment now describes Dismiss as suppressing the candidate, matching
  the UI copy.
- Static guards prevent the old `Not me` label and `Dismisses this detection`
  hint from returning inside the sleep review card.

What did not change:
- No sleep/nap detection, confirmation save logic, dismissal storage,
  adjustment sheet, recovery math, notifications, or Liquid Glass layout
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Runtime UI snapshot showed `Review your sleep`, `Review first`, `Confirm
  sleep`, `Adjust`, and `Dismiss`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-dismiss-action.jpg`.

## Sleep review window-strip counts checkpoint - July 1, 2026

This pass makes the compact sleep review summary easier to understand at a
glance. The small strip now answers "what happens if I save this?" without
requiring the user to interpret `Recovery` as an action.

What changed:
- Added a separate `windowStripImpactText` for the compact strip.
- Main sleep now shows `Counts` in the compact strip instead of `Recovery`.
- Nap review still shows `Separate`.
- The deeper night arc still keeps the recovery context: `counts Recovery`.
- Static guards prevent the compact strip from being wired back to
  `windowImpactText`.

What did not change:
- No sleep/nap classification, recovery calculation, confirm/adjust/dismiss
  behavior, notification copy, source policy, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Runtime UI snapshot showed `Main sleep. Full night. Counts.`, visible
  `Main sleep`, `Full night`, and `Counts`; the night arc still showed
  `counts Recovery`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-window-strip-counts.jpg`.

## Workout review strap-window wording checkpoint - July 1, 2026

This pass removes grading-style capture labels from the saved workout review
banner. The user now sees an action-oriented strap-window step instead of
`Enough`, `Check`, or `Patchy`.

What changed:
- Saved workout review accessibility now says `Strap window ...` instead of
  `Strap capture ...`.
- The review path accessibility now says `strap window ...`.
- The strap step labels now resolve to `Ready`, `Review`, or `Check time`.
- The low-coverage saved workout fixture now shows `Check time` instead of
  `Patchy`.
- Static guards prevent `Enough`, `Check`, `Patchy`, and old `strap capture`
  wording from returning inside `AtriaSavedWorkoutReviewBanner`.

What did not change:
- No workout detector thresholds, coverage math, saved-session logic,
  exercise labeling flow, notification copy, source policy, or Liquid Glass
  layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  saved-workout-review`.
- Runtime UI snapshot showed `Workout review path. Review the window, strap
  window Check time, then save after labeling.`, plus visible `Strap`,
  `Check time`, `Review & label`, and `Dismiss`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-check-time.jpg`.

## Workout type step instruction checkpoint - July 1, 2026

This pass makes the workout review type step more direct. The user is already
inside a guided review flow, so the subtitle now tells them the action instead
of explaining an activity-history label.

What changed:
- The type step subtitle now reads `Pick what you want saved.`
- Static guards prevent the old `Choose the label you would expect to see in
  your activity history.` wording from returning.

What did not change:
- No workout type list, exercise catalog, suggested activity logic, save flow,
  source policy, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-review-flow --atria-workout-review-type-step`.
- Runtime UI snapshot showed `What type was it?`, `Pick what you want saved.`,
  `Suggested from strap HR`, `Strength`, `Cardio`, and `Functional`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-type-pick-saved.jpg`.

## Workout exercise catalog prompt checkpoint - July 1, 2026

This pass makes the exercise selection step feel more like a guided fallback
than a hidden catalog. The user still sees likely moves first, and search stays
available only when they need more.

What changed:
- The exercise catalog preview now says `Search full catalog`.
- The accessibility label now says `Search full exercise catalog. ... groups
  ready when needed.`
- Static guards prevent the old `Full catalog waits behind search` wording from
  returning.

What did not change:
- No exercise catalog contents, search/filtering logic, selected-exercise save
  behavior, workout type flow, source policy, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-review-flow --atria-workout-review-exercises-step`.
- Runtime UI snapshot showed `Add exercises`, `Likely moves`, `Search only if
  needed`, `Search full catalog`, and `14 groups ready when needed`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-exercise-search-full-catalog.jpg`.

## Workout summary remember-label checkpoint - July 1, 2026

This pass makes the final workout save receipt feel local and user-owned. The
receipt no longer says Atria will `Learn` from the label; it says Atria will
`Remember` it.

What changed:
- The final summary memory rail now uses `Remember` instead of `Learn`.
- The summary accessibility label now says Atria `remembers the selected label`.
- Static guards prevent the old `Learn` node and `learns from the selected
  label` wording from returning.

What did not change:
- No workout save behavior, exercise selection, workout type selection,
  Health export queue, source policy, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-review-flow --atria-workout-review-summary-step`.
- Runtime UI snapshot showed the summary receipt and accessibility text:
  `After save, Atria adds the workout to history and remembers the selected
  label.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-summary-remember-label.jpg`.

## Trend assessment change-label checkpoint - July 1, 2026

This pass keeps trend language consistent across the app. The active trend
assessment card no longer uses `Move`; it now uses the same `Change` wording as
the metric-detail and trend-summary surfaces.

What changed:
- `AtriaTrendRangeAssessmentCard` now labels the movement bar as `Change`.
- The assessment accessibility text now says `change ...` instead of
  `movement ...`.
- Scoped static guards prevent `assessmentBar(label: "Move",` and
  `movement \(movementText)` from returning inside the assessment card.

What did not change:
- No trend data preparation, chart rendering, range controls, metric math,
  source policy, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime UI snapshot verified the trend surface rendered with month summary,
  prior comparison, current-position band, and day pattern. The assessment-card
  `Change` label is source/test verified; it was not visible in the captured
  fold for the selected metric/range.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trend-assessment-change-label.jpg`.

## Trend summary prior-label checkpoint - July 1, 2026

This pass makes the active trend summary comparison pill less jargon-like. The
four-pill summary now reads `Latest`, `Avg`, `Range`, and `Prior` when a prior
window exists.

What changed:
- The prior-comparison pill now says `Prior` instead of `Vs prior`.
- The trend summary accessibility text now says `prior change ...` instead of
  `versus prior ...`.
- Scoped static guards prevent `Vs prior` and `versus prior` from returning in
  `AtriaTrendRangeSummaryStrip`.

What did not change:
- No trend comparison math, range selection, chart rendering, source policy, or
  Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime UI snapshot showed `Trend summary. Latest 60 bpm, average 60 bpm,
  range 58-62 bpm, prior change -2 bpm.`, plus visible `Latest`, `Avg`,
  `Range`, and `Prior`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trend-summary-prior.jpg`.

## Trend time-window dock checkpoint - July 1, 2026

This pass makes the trend range control read more like a user choice. The dock
above the `D/W/M/3M/6M` controls now says `Time window` instead of `Range`, while
the summary pills can still use `Range` for the actual low-to-high metric span.

What changed:
- `AtriaTrendRangeDock` now labels the date-window selector as `Time window`.
- The existing day coverage status such as `31 days in view` stays unchanged.
- Static checks now assert the new dock label.

What did not change:
- No trend math, data preparation, range selection behavior, source policy,
  notification behavior, workout detection, sleep detection, or Liquid Glass
  layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-ui-fixture trend-prior-comparison`.
- Runtime snapshot after launch showed the app in real empty/disconnected state
  rather than the trend fixture fold, so this copy change is source/test/build
  verified rather than visually verified on the rendered trend dock in this
  pass.
- Visual evidence of the simulator state captured after the build:
  `artifacts/visual-checks/simulator/20260701-trend-time-window-dock.jpg`.

## Live sleep-review truth + morning wording checkpoint - July 1, 2026

This pass used the cabled physical iPhone first, then made the morning sleep
review moment easier to consume. The phone now has a real overnight sleep window
waiting for user confirmation, so the UI should lead with review instead of
developer-ish sync or generic sleep language.

Physical-iPhone evidence:
- Copy-only pull, no build/launch/termination:
  `artifacts/live-device/20260701-170522-goal-continuation-pull/`.
- Atria process was running; official WHOOP process was not listed.
- Strap battery state was not stale charging:
  `battery_level=60`, `battery_source=live_2A19`,
  `battery_charge_status=notCharging`, `battery_is_charging=0`.
- No phone-motion sessions were present:
  `phone_motion_sessions=0`, `phone_motion_nonzero_sessions=0`.
- Overnight candidate now exists and is pending review:
  `pending_sleep_review_status=pending_user_confirmation`,
  `pending_sleep_review_kind=sleep`,
  `pending_sleep_review_start=2026-07-01T00:33:01.630880+05:30`,
  `pending_sleep_review_end=2026-07-01T08:46:29.830866+05:30`,
  `pending_sleep_review_duration_s=29608`.
- The active journal still needs deeper reliability work:
  `active_journal_freshness=stale`,
  `active_journal_continuity_status=stalled`,
  `active_journal_rr_gate_b_local_blocker=rr_gap_178.6s_gt_3s`.

What changed:
- Main overnight sleep review cards now say `Review last night` instead of
  `Review your sleep`; nap review still says `Review your nap`.
- Sleep-review notifications use the same `Review last night` title for main
  overnight sleep.
- `AtriaSleepSyncNeededHost` now defers to any reviewable sleep candidate found
  by `latestSleepReviewNightForUI(...)`, so a user does not see `Sync sleep data`
  competing with a real review card.
- The debug `pending-sleep-review` fixture also suppresses the sync prompt so
  simulator screenshots represent the intended morning hierarchy.

What did not change:
- No sleep scoring, sleep/nap detector thresholds, stage estimation, recovery
  math, source policy, HealthKit/CoreMotion source, workout detection, or Liquid
  Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Runtime UI snapshot showed `Review last night`, `Confirm sleep`, `Adjust`,
  `Dismiss`, the strap-HR review path, and no competing `Sync sleep data` prompt
  in the review moment.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-last-night.jpg`.

## Workout found confirmation wording checkpoint - July 1, 2026

This pass follows the current WHOOP pattern of treating auto-detected activity as
a confirmation moment: the app found an effort window, then the user confirms the
type or dismisses it. It does not make Atria more aggressive about detection.

Current WHOOP references checked:
- WHOOP 2026 updates call out more accurate workout detection and labels,
  especially strength training, functional fitness, lower-strain sustained
  activity, and fewer generic `Activity` labels:
  `https://www.whoop.com/us/en/thelocker/2026-whats-new/`.
- WHOOP support still describes automatic activity detection as based on elevated
  heart rate, movement patterns, and strain, with manual activity editing:
  `https://support.whoop.com/s/article/Automatic-and-Manual-Activity-Detection`.
- WHOOP trend direction remains weekly/monthly/6-month context for Sleep,
  Strain, and Recovery:
  `https://www.whoop.com/us/en/thelocker/track-progress-with-new-trend-views/`.

What changed:
- Workout-review notifications now title strong candidates as `Workout found`
  and lower-confidence effort candidates as `Effort found`.
- Workout-review notification body now says `Confirm type or dismiss.` for
  workout candidates instead of `Choose type or dismiss.`
- The saved workout review card primary action now says `Confirm type` instead
  of `Review & label`.
- The saved workout review accessibility label now says `Confirm type before
  saving.`

What did not change:
- No workout detector thresholds, source policy, HealthKit/CoreMotion source,
  workout storage, exercise catalog, sleep logic, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  saved-workout-review`.
- Runtime UI snapshot showed `Effort ready to review`, strap-HR window evidence,
  and the primary `Confirm type` action.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-confirm-type.jpg`.

## Review prompt priority checkpoint - July 1, 2026

This pass fixes a hierarchy issue found during the workout-review fixture check:
the primary workout review card could be followed immediately by lower-priority
`Sync sleep data` guidance. That made the screen feel like a diagnostic stack
instead of one clear user decision.

What changed:
- `AtriaHomeView` now passes `hasPrimaryReviewAction` into the Overview content
  as `suppressSleepSyncPrompt`.
- `AtriaOverviewTabContent`, `AtriaOverviewLeadingHost`, and
  `AtriaOverviewLeadingSection` thread that flag to `AtriaSleepSyncNeededHost`.
- `AtriaSleepSyncNeededHost` now hides when a primary review action is already
  active, unless a debug fixture explicitly requests the sync card.

What did not change:
- No sync/backfill behavior, sleep detection, workout detection, notifications,
  source policy, HealthKit/CoreMotion source, or Liquid Glass layout changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  saved-workout-review`.
- Runtime UI snapshot showed `Effort ready to review`, strap-HR window evidence,
  and `Confirm type`; `Sync sleep data` was no longer present in the review
  moment.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-no-sync-competition.jpg`.

## Workout review after-type checkpoint - July 1, 2026

This pass tightens one remaining workflow phrase in the saved workout review
card. The path now matches the primary action (`Confirm type`) instead of using
the more mechanical `label` wording.

What changed:
- The saved workout review path now says `Save` / `After type` instead of
  `Save` / `After label`.
- The accessibility summary now says the workout saves after `confirming type`
  instead of after `labeling`.
- Static guards prevent `After label` and `save after labeling` from returning
  in the saved workout review banner.

What did not change:
- No workout detector thresholds, source policy, HealthKit/CoreMotion source,
  workout storage, notification behavior, sleep logic, or Liquid Glass layout
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  saved-workout-review`.
- Runtime UI snapshot showed `Save`, `After type`, and
  `Workout review path. Review the window, strap window Check time, then save
  after confirming type.`
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-after-type.jpg`.

## Workout review decision-language checkpoint - July 1, 2026

This pass removes another small but user-visible developer smell from the
workout review flow. The review screen now presents the choice as a calm user
decision instead of an internal detector verdict.

What changed:
- The workout review evidence strip now says `Ready to confirm` or
  `Check timing` instead of `Ready to label` / `Needs review`.
- The guided time step now includes a compact decision preview so users see the
  whole path early: confirm the type, adjust time, or dismiss it.
- The negative choice now says `Dismiss` instead of `Reject`, with matching
  accessibility copy: `Workout review choices. Confirm type, adjust time, or
  dismiss.`

What did not change:
- No workout detector thresholds, strap source policy, HealthKit/CoreMotion
  source behavior, workout storage, notification scheduling, sleep logic, or
  Liquid Glass visual thesis changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-review-flow`.
- Runtime UI snapshot showed `Workout review choices. Confirm type, adjust
  time, or dismiss.` plus the `Confirm`, `Adjust`, and `Dismiss` actions inside
  the guided time step.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-flow-confirm-adjust-dismiss.jpg`.

## Trends balance-map checkpoint - July 1, 2026

Current WHOOP research reinforced that longer-range views should make weekly,
monthly, and 6-month patterns understandable before users dig into detailed
charts. WHOOP's May 20, 2026 Trend Views update explicitly frames Sleep,
Strain, and Recovery as weekly/monthly/6-month trend views, and WHOOP support
also describes weekly, 1-month, and 6-month trend patterns across Strain,
Recovery, Sleep, and Stress.

What changed:
- `AtriaTrendChartCard` now surfaces the visual `AtriaTrendPeriodBalanceMap`
  immediately after the range dock when there is enough period signal.
- The denser `AtriaTrendGlanceBoard` remains, but it now comes after the map so
  the first trend viewport reads as range -> balance story -> metric details.
- Static checks now require the balance map to appear before the metric board,
  preventing the trends screen from drifting back into a text-first stack.

What did not change:
- No metric formulas, source policy, HealthKit/CoreMotion source behavior,
  workout/sleep detection, notification scheduling, trend data preparation, or
  Liquid Glass visual thesis changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime UI snapshot showed `Last 30 days · 31 days`, the range dock, then
  `Balance map. Recovery reserve 74 percent. Load pressure 53 percent. Cue
  Ready.`, followed by the existing `Trend glance`.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-balance-map.jpg`.

Research references:
- WHOOP Trend Views, May 20, 2026:
  `https://www.whoop.com/us/en/thelocker/track-progress-with-new-trend-views/`
- WHOOP Viewing Trends support:
  `https://support.whoop.com/s/article/Viewing-Trends`

## Trends range-language checkpoint - July 1, 2026

This pass tightens the visible trend range model so Atria speaks like a user
facing trend view rather than a data-window picker.

What changed:
- The mounted `AtriaTrendRangeDock` label now says `Ranges` instead of
  `Time window`.
- The compact trend summary card now uses a visual D/W/M/3M/6M ladder instead
  of the stale `Range 90d` chip. That summary card is not currently the primary
  mounted Trends path, but its guardrail now matches the real range model.
- Static checks now prevent the old `Time window`, `Range`, and `90d` wording
  from returning in these trend range controls.

What did not change:
- No trend data preparation, metric formulas, source policy, workout/sleep
  detection, notification scheduling, or Liquid Glass visual thesis changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime UI snapshot showed `Ranges`, `D`, `W`, `M`, `3M`, `6M`, coverage
  counts, the `Balance map`, and the `Trend glance` in the first Trends
  viewport.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-ranges-label.jpg`.

## Today plan leaner hierarchy checkpoint - July 1, 2026

This pass removes repeated information from the top Today plan card. The card
already had the right visual story: readiness mark, day lane, tonight sleep
plan, and balance rail. The extra bottom pill row repeated strain, sleep debt,
and baseline/recovery in a more text-heavy way, so it was removed.

What changed:
- `AtriaOverviewGuidanceSection` now ends after `planBalanceRail`.
- The old bottom `planPill` row and `planPill(...)` helper were removed.
- Static checks now enforce the lean order:
  `AtriaDayPlanLane` -> `AtriaSleepPlanStrip` -> `planBalanceRail`, and forbid
  the old duplicate `planPill` row.

What did not change:
- No recovery/strain/sleep guidance logic, metric formulas, source policy,
  detection, notification scheduling, or Liquid Glass visual thesis changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today`.
- Runtime UI snapshot showed `Today's Plan`, `Day lane`, `Tonight sleep plan`,
  and no bottom duplicate `Strain` / `Sleep debt` / `Baseline` pill row in the
  plan card.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-today-plan-leaner.jpg`.

## Sleep review leaner hierarchy checkpoint - July 1, 2026

This pass trims duplicated evidence from the sleep review card. The card already
had the user decision, compact review path, and night arc; the extra bottom
window strip repeated the same mode/quality/count story and made the review
feel more like a diagnostic stack.

What changed:
- Removed the mounted `AtriaSleepReviewWindowStrip` from
  `AtriaSleepReviewCard`.
- Removed the unused window-strip helper and its `windowModeText`,
  `windowQualityText`, and `windowStripImpactText` plumbing.
- Static checks now enforce action buttons -> compact path -> night arc and
  forbid the removed duplicate window-strip branch.

What did not change:
- No sleep detection, nap/sleep classification, confirm/adjust/dismiss behavior,
  notification scheduling, source policy, metric formulas, or Liquid Glass
  visual thesis changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  pending-sleep-review`.
- Runtime UI snapshot showed `Review last night`, `Confirm sleep`, `Adjust`,
  `Dismiss`, the compact `Sleep review path`, then `Sleep review night arc`,
  with no extra bottom window strip before Today's Plan.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-sleep-review-leaner.jpg`.

## Workout review human-language checkpoint - July 1, 2026

This pass makes the first workout review step read like a user decision instead
of detector diagnostics. The rendered time step now shows what Atria saw before
asking the user to adjust start/end, and the duplicate Now/Next rail was removed
so the form is easier to consume before tapping Continue.

What changed:
- Replaced review evidence labels from `Review check` / `Capture` / `Save` with
  `What Atria saw` / `Signal` / `Next`.
- Mounted the evidence strip at the top of the `Confirm time` step, before the
  Start and End controls.
- Removed the rendered duplicate step-context rail from the review stepper while
  preserving the accessibility step context.
- Changed non-exercise activity copy from `Label only` to `Type only`.

What did not change:
- No workout detector thresholds, strap-only source policy, save behavior,
  exercise catalog, notification scheduling, or Liquid Glass visual thesis
  changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment today --atria-ui-fixture
  workout-review-flow`.
- Runtime visual check showed `What Atria saw`, `Signal`, `Next`, Start, and End
  visible in the first decision step, without the duplicate Now/Next rail.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-workout-review-human-language.jpg`.

## Trends range-report checkpoint - July 1, 2026

WHOOP's current direction keeps emphasizing less manual logging, clearer
activity classification, and period trend views that connect Recovery, Strain,
and behavior instead of leaving users to interpret raw charts. This pass applies
that to Atria's Trends tab by putting the period answer before the detailed
metric board.

What changed:
- Mounted `AtriaTrendRangeReportCard` in the Trends card when enough period
  signal exists.
- Ordered the trend summary as: compact `Range report`, visual `Balance map`,
  then denser `Trend glance`.
- Static checks now enforce that answer-first ordering and continue to forbid
  older unused period hero/orbit/readout stacks.

What did not change:
- No trend calculations, saved-session sources, period ranges, activity
  detection, notifications, or Liquid Glass visual thesis changed.

Validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
- Debug simulator build/install/launch passed via XcodeBuildMCP on
  `51BECE0B-0745-4808-B033-6D6D8A39DC33` with
  `--atria-developer-mode --atria-complete-onboarding --atria-ui-screen
  overview --atria-ui-overview-segment trends --atria-ui-fixture
  trend-prior-comparison`.
- Runtime visual check showed `Range report` with Best signal, Pressure, and
  Next visible in the first Trends viewport before `Balance map`.
- Research references checked:
  WHOOP "What's Next" Spring 2026 and WHOOP Activity and Sleep Detection support
  page.
- Visual evidence:
  `artifacts/visual-checks/simulator/20260701-trends-range-report.jpg`.

## Latest completion status - July 2, 2026

This tail section supersedes the older incremental checkpoints above. The
remaining work from this handoff is now complete: the final fresh Release
runtime proof was captured on the paired physical iPhone after the device was
unlocked.

Current simulator proof covers the main requested surfaces:

- Today plan:
  `artifacts/visual-checks/simulator/20260701-today-plan-leaner.jpg`.
- Trends ranges and summaries:
  `artifacts/visual-checks/simulator/20260701-trends-range-report.jpg`.
- Workout detection:
  `artifacts/visual-checks/simulator/20260701-workout-detection-signal-language.jpg`.
- Workout review:
  `artifacts/visual-checks/simulator/20260701-workout-review-human-language.jpg`.
- Sleep review:
  `artifacts/visual-checks/simulator/20260701-sleep-review-stale-branch-cleanup.jpg`.
- Live workout:
  `artifacts/visual-checks/simulator/20260701-live-workout-reduce-motion-heart.jpg`.

Current implementation status:
- Native Liquid Glass direction is preserved across Today, Trends, Live workout,
  Sleep review, Workout detection, and Workout review.
- Today, Trends, Sleep review, and Workout review have visual simulator proof
  linked below.
- Workout review now surfaces strength-like fragmented strap evidence as a
  reviewable user decision instead of silently dropping it, while strict
  auto-count/export remains gated.
- Sleep review surfaces the overnight window as pending user confirmation
  instead of fabricating stages or auto-scoring uncertain data.
- Strap-only source boundary is guarded: no phone-motion or phone-step workout
  source is allowed.
- The final handoff is now compacted at this tail so future work should start
  here instead of replaying old duplicate checkpoints.

Fresh physical-device attempt:
- Release build/install command:
  `ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B ./live_device_debug.sh --release --seconds 90 --log docs/evidence/final-device/20260701T195954Z-handoff23-final-release/live-device.log --log-collection-health-after 60 --log-activity-detections --log-daily-rollups --log-workout-preflight --schedule-notifications --leave-running --pull-sessions docs/evidence/final-device/20260701T195954Z-handoff23-final-release/current-container`
- Result: `** BUILD SUCCEEDED **` and app install succeeded.
- Runtime blocker: launch was denied by iOS because the device was locked:
  `Unable to launch com.adidshaft.atria because the device was not, or could not
  be, unlocked`.
- Evidence directory:
  `docs/evidence/final-device/20260701T195954Z-handoff23-final-release`.
- Retry evidence:
  `docs/evidence/final-device/20260701T200135Z-handoff23-final-release-retry`.
  The retry again built and installed Release successfully, then hit the same
  iOS locked-device launch denial before any `ATRIADBG` runtime rows could be
  emitted.
- Second retry evidence:
  `docs/evidence/final-device/20260701T200304Z-handoff23-final-release-retry2`.
  This third consecutive goal attempt again built and installed Release
  successfully, then hit the same iOS locked-device launch denial before any
  `ATRIADBG` runtime rows could be emitted.

Final physical Release proof:
- Evidence directory:
  `docs/evidence/final-device/20260701T200835Z-handoff23-final-release-resumed`.
- Release build/install/launch succeeded on the paired physical iPhone.
- Atria connected to the strap in Release and emitted 432 `ATRIADBG` rows.
- Live strap HR was updating from the standard heart-rate characteristic:
  examples included 57, 71, 72, 74, 76, 77, 78, 79, 81, 82, 83, then back down
  to the mid-60s.
- Strap battery was refreshed from live `2A19` at 57%, with
  `notification_battery_decision level=57 source=live_2A19 age_s=0 usable=1`
  and `charge=levelOnly`, so the stale charging-state issue was not reproduced.
- Collection health completed with `status=ready blocker=none`, and the pulled
  active segments reported `delta_samples=58`, `delta_rr=11`, `battery=57`,
  `latest_bpm=63`, and `label=Long_wear`.
- Workout review was visible in the foreground screenshot as a reviewable strap
  HR window: `8:22 PM-9:09 PM`, `47m from strap HR`, peak 164, average 115.
- Sleep review was scheduled from the aggregate sleep candidate:
  `sleep_review_candidate source=notification_sleep_review candidate_source=aggregate_sleep`
  and `notification_scheduled kind=sleep_review`.
- Atria was left running in normal end-user mode:
  `HARNESS_LEAVE_RUNNING status=launched mode=normal_end_user`.
- Foreground physical screenshot:
  `docs/evidence/final-device/20260701T200835Z-handoff23-final-release-resumed/foreground.png`.

Final go/no-go:
- Go. The final Release runtime proof and foreground physical screenshot have
  been captured. No handoff-specific go/no-go work remains.

Latest validation:
- `python3 -m unittest test_handoff_static_checks.HandoffStaticChecks` passed.
- `git diff --check` passed.
