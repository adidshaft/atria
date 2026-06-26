# Codex Handoff — Customizable Layout, WHOOP 4.0 Metrics, Connection Diagnostics

Date: 2026-06-26
Owner-requested. This is a **build spec** for Codex to execute. Read
`docs/20-codex-combined-handoff.md` (the master to-do + the "DO NO HARM" rules and
the A0/A0′ perf lessons) and `docs/18-codex-advanced-metrics-handoff.md` (the honest
metric tiers) FIRST — they govern everything here.

## Non-negotiables (verify on every change)
- **No lag.** No heavy compute in a `var body` or computed `some View` property; no
  `dailyRollups`/`detectedActivity`/O(sessions×detection) on the launch/render path
  (see docs/20 §A0). All derived numbers come from a cached `@Published` recomputed
  off the hot path (background queue → publish on main). Judge perf on a **Release**
  build only (docs/20 §A0′: Debug is 30–50× slower and not representative).
- **Local-first.** No cloud/account/network; keep `test_handoff_static_checks.py`
  green (43); no `https://`.
- **Honest metrics.** Every score is tiered (docs/18). NEVER fabricate HRV/Recovery/
  Sleep from data the strap didn't actually provide. Gate on the detected model. A
  metric with insufficient evidence shows a "learning/building baseline" state, never
  a fake number.
- **Status truth (already shipped).** `AtriaBLEManager.status` is a PURE derived
  function of CoreBluetooth ground truth (`recomputeConnectionStatus` /
  `derivedConnectionStatus`). NOTHING else may write `status` (it is `private(set)`).
  The top chip distinguishes connected-vs-contact ("Live" only with `hasContact`).
- **Build → static-green (43) → install on the cabled iPhone (Release) → commit
  small.** Project is now `Atria/Atria.xcodeproj`, scheme `Atria`; log tag is
  `ATRIADBG`; launch flags are `--atria-*`.

Code lives in `Atria/Atria/`. Key files: `AtriaHomeView.swift` (home shell + the
`AtriaHomeModel` stores), `AtriaOverviewSections.swift` (Overview glance + cards),
`AtriaVitalsCollectionSections.swift` (Vitals + Data tabs), `Sessions.swift`
(`SessionStore`, the derived-metrics home), `AtriaBLEManager.swift` (BLE + status).

## 2026-06-27 progress

- **Part A started:** Overview glance cards now use a persisted
  `atria.overview.glanceOrderCSV` order on top of the existing
  `AtriaTodayMetric` visibility model. The rendered cards support drag/drop
  reordering by stable enum IDs, and Settings -> Today exposes the same order with
  scroll-safe up/down controls for precise fallback editing. Vitals now has a separate
  persisted `atria.vitals.sectionOrderCSV` and drag/drop for the large sections
  only: Pulse, HRV, Recovery/Strain, and Profile.
- **Part C started:** Today now shows a calm inline `AtriaConnectionDiagnosis`
  banner for ground-truth actionable states: Bluetooth off, Bluetooth permission
  denied, connected/no pulse, searching/connecting, disconnected, low strap
  battery, and official WHOOP app coexistence when `whoop://` is actually
  installed. No modal or polling was added.
- **Perf cleanup:** the research maneuver probe correlation and developer-only
  IMU audit summaries are now cached in `SessionStore`, recomputed only when
  sessions or local probe markers change, and read O(1) by the Data cards.
  `SessionDetail` now downsamples chart points once at init instead of recomputing
  the downsampled series on every render. The connected pulse status card now
  receives a precomputed display name from core live state, avoiding string parsing
  during live HR updates. History now opens from a `SessionStore` snapshot cache:
  saved sessions render immediately, while activity detections, trend summaries,
  and daily rollups fill after the first render instead of running on the
  navigation path.
- **Part B radio trade-off surfaced:** Settings now has a user-facing **Battery
  saver** radio-mode toggle. It uses the existing reconnect-aware
  `setStandardHROnlyEnabled` path and explains that standard HR keeps heart rate
  live while RR-gated HRV/Recovery/sleep detail waits for validated RR windows.
- **Uniformity pass started:** top-right toolbar actions now share one fixed-size
  icon label, Data toggle cards allow two-line explanatory copy, and Settings
  Appearance uses the same cheap inset-card chrome as other panels instead of
  custom glass inside a scrolling form. The shared `atriaGlassSelectable`
  compatibility helper now maps to cheap `AtriaSegmentButtonStyle` chrome, so
  in-scroll segmented choices and tags no longer instantiate repeated glass
  controls. Card-body actions now use a shared `AtriaCardActionButtonStyle`
  instead of repeated `.glass/.glassProminent`, including Data export/import/share,
  probe markers, overview CTAs, Settings reorder controls, inline banners,
  connection/setup actions, profile steppers, AI coach key actions, onboarding
  primary action, and workout stop.
  The Overview backup/Data card now uses a two-row layout so text, HRV-window
  status, and the Data action do not squeeze each other, reconnect checklist rows
  can wrap, and Vitals/Data profile/coexistence panels use inset/card hierarchy
  instead of nested raised cards.
- **Verification:** `python3 test_handoff_static_checks.py` is green (50), and
  Release builds have been installed on the cabled iPhone. Static guards now pin
  the handoff-21 ordering, diagnosis behavior, UI uniformity, and render-path
  cache behavior.

---

## PART A — Drag-and-drop customizable layout

GOAL: the user arranges what they see "at a glance." Long-press a card → it lifts →
drag to reorder → drop. The arrangement persists per-user. Two scopes:

### A1. Overview ("Today at a glance") — ALL glance cards reorderable
The owner confirmed: **every** glance card is draggable — Recovery, Strain, HRV,
Sleep, RHR, Steps, kcal (and any new metric cards from Part B). The user can both
**reorder** and **show/hide** (an existing hide mechanism is `AtriaTodayMetric` +
`AtriaTodayMetric.storageKey` in Settings → Today; fold reordering into the same
model).

Implementation:
- Model: introduce `AtriaGlanceCard` enum (`recovery, strain, hrv, sleep, rhr, steps,
  kcal, …`) with a stable `id`. Persist an **ordered, filtered** list in
  `@AppStorage` (e.g. `atria.overview.glanceOrderCSV`) — order = arrangement,
  membership = visibility. Reuse/extend `AtriaTodayMetric` rather than adding a
  parallel system; today it only hides, make it also order.
- UI: render the glance grid from the persisted order. Use a real reorder mechanism:
  `.draggable`/`.dropDestination` (iOS 16+) or a long-press + `matchedGeometryEffect`
  drag, with haptic on lift (`AtriaHapticAlertSettings` exists). Keep cells CHEAP —
  the cards already exist; just reorder them. Do NOT introduce `.glassEffect` on the
  moving cells (perf; docs/20). A simple "edit mode" (wiggle/handle) is acceptable if
  free-drag is too heavy on device — validate scroll perf on **Release**.
- Persistence: write order on drop; read on appear; O(1). Never recompute metrics on
  reorder.
- Scope guard: **drag-and-drop is Overview-only.** Vitals/Data do NOT free-reorder.

### A2. Vitals — larger draggable sections (coarser granularity)
Owner: "the draggable assets will be the larger ones … not the smaller ones like the
overview side." So on **Vitals**, the draggable units are the **big cards**
(Pulse, HRV, Recovery/Strain, Profile — `AtriaVitalsTabContent`), reordered as whole
sections, persisted separately (`atria.vitals.sectionOrderCSV`). Same mechanism,
coarser units.

### A3. Uniformity pass on Vitals + Data (owner asked separately)
While here: make Vitals AND Data **uniform** — one button style, one card chrome,
**remove duplications** (e.g. metrics repeated between hero and glance; redundant
controls). No drag-drop on the small tiles there. This is the "make everything very
uniform, remove any kind of duplications" ask.

DoD for Part A: on a Release build, long-press-drag reorders Overview glance cards
smoothly (no jank), the order persists across launches, Vitals reorders big sections,
and Vitals/Data look uniform with no duplicate controls.

---

## PART B — Metrics users want from a WHOOP 4.0 strap

Owner wants, explicitly: **Recovery, Steps, Strain, HRV, Sleep, Body temperature,
Sleep history, VO₂max, Recovery + HRV in general — and anything else a 4.0 strap can
provide that users desperately want.** Build these through the cached derived store
(never in `body`), each in its honest tier (docs/18). Status of each today:

| Metric | 4.0 source | Status / what to build | Tier rule |
|---|---|---|---|
| **Heart rate (live)** | 0x2A37 + 0x28 realtime | ✅ live. | direct |
| **HRV (RMSSD)** | RR intervals (0x2A37 RR-flag / 0x28) | RR is the bottleneck — strap only emits RR with good contact/activity (see §B-RR). Compute RMSSD over a clean RR window; **morning/sleep HRV** is the headline. | needs validated RR window |
| **Recovery** | HRV + RHR + sleep | Score = f(HRV vs personal baseline, RHR vs baseline, sleep). Show "building baseline" until N nights. Proxy `max(0,100-strain*4)` is a FALLBACK only — label it. | derived, baseline-gated |
| **Strain (day + workout)** | HR over time (TRIMP/Banister) | ✅ `Metrics.strain(fromTRIMP:)` exists; accumulate across day like WHOOP. | derived |
| **Steps / distance / floors** | strap IMU (0x33) vs `CMPedometer` | Phone pedometer is live (adjunct). Strap-step research exists (`AtriaStrapStepResearch`) — validate strap steps vs phone before promoting. | research → validated |
| **Sleep (stages, duration, efficiency)** | overnight HR + RR + IMU motion | Detect sleep/wake from HR dip + motion (`AtriaSleepWakeResearch` scaffold). Stages need RR/HRV + motion; ship duration+efficiency first, stages as research. | research → validated, sleep-only |
| **Sleep history** | saved sessions | Timeline of past nights (duration, efficiency, HRV, RHR trend). Read from `SessionStore` derived cache; chart per night. | derived from saved |
| **VO₂max estimate** | HR/HRR + pace/age | `profileMetricsStore.vo2MaxEstimate` exists — polish + show trend. | estimate, labeled |
| **Body / skin temperature** | 0x33 sensor probe (research) | `AtriaResearchProbe` decodes candidate skin-temp frames. NO absolute °C without a reference — show **deviation from baseline** only, research-gated, sleep-only. | research, relative-only |
| **SpO₂ (blood oxygen)** | 0x33 sensor probe (research) | Same probe path; candidate frames only. Research-gated, never written to HealthKit, never an absolute %. | research, relative-only |
| **Resting HR** | overnight/low-activity HR min | ✅ baseline exists. Surface trend. | derived |
| **Respiratory rate** | RR-derived (during sleep) | Derivable from RR/HR modulation during sleep — research tier. | research, sleep-only |

### B-RR — the gating dependency (do this first; it unblocks HRV/Recovery/Sleep)
On-device finding: in low-radio mode the strap sends ~1 Hz HR but **zero RR** at
rest; RR flowed at HR ~108 (activity) and shows `rr_quality state=poor_contact` when
the strap is loose/off. The proprietary realtime (0x28) START command (`cmd=03`,
`aa0800a82300030199bce9cf`) is sent but the strap returns sparse data on this unit.
TASKS:
1. Get a steady RR stream: validate the realtime-arming sequence against the macOS
   reference (timing, `withResponse` vs `withoutResponse`, char order). Confirm
   whether RR must come via 0x2A37 (RR-flag) or 0x28 and under what contact/mode.
2. Surface a **contact/quality coach**: when connected + `poor_contact`, tell the
   user to tighten the strap / wet the sensor (ties into Part C).
3. Only feed HRV/Recovery from a clean RR window with enough beats; else "building".
4. DECIDE the radio default trade-off (docs/20 §3): full-protocol (RR, more strap
   drain) vs standard-HR-only (battery). Add a Settings **"Battery saver"** toggle;
   do NOT silently flip the default — full-protocol broke total throughput on this
   unit, so measure before defaulting.

### B-HISTORICAL — unlock the offline archive for metrics (owner asked)
The app already **downloads** missed offline data on reconnect
(`requestOfflineHistoricalSyncIfNeeded`) into a historical archive, but it is
deliberately **barred from metrics** (`historicalArchive … metric_usable=0`) because
the historical RR layout isn't validated (docs/03). TASK: validate the historical RR
layout against an external RR/IBI reference; once validated, let backfilled history
feed Recovery/HRV/Sleep so a gap (phone away, app closed) fills in "with time" as the
owner wants. Keep the honesty gate until validated.

DoD for Part B: each metric either shows a real, tier-honest value with a trend, or a
clear "building baseline"/"research" state — never a fabricated number. All computed
in the derived store, nothing heavy in a `body`.

---

## PART C — Connection diagnostics + actionable notification

Owner: "where the device is disconnected, Bluetooth is off … the app should detect
WHY the strap is not connected/detectable and notify the user for action."

Build a single `AtriaConnectionDiagnosis` derived from ground truth (the derived
status already exists — extend it), mapping the real cause → a one-line action:

| Detected condition | Signal | User-facing action |
|---|---|---|
| Bluetooth off | `central.state == .poweredOff` | "Turn on Bluetooth in Settings." |
| BT permission denied | `.unauthorized` | "Allow Bluetooth for Atria in Settings." |
| Strap out of range / app can't find it | saved strap, pending connect, no connect for N s | "Bring your strap closer / it may be off your wrist." |
| Connected but no pulse (off-wrist/loose) | `status==.connected && !hasContact` (poor_contact) | "Strap's connected but not reading — tighten the fit." |
| Low strap battery | `batteryLevel` low + drops | "Charge your strap — battery low." |
| Stale pairing / phantom contention | short-disconnect heuristic (NO WHOOP installed) | "Forget the strap in Settings → Bluetooth, then reconnect." |
| Official strap app installed & may grab BLE | `canOpenURL("whoop://")` true | the existing coexistence modal (only when truly installed). |

Surface as: (1) the chip already differentiates Live/No signal/Bluetooth off/
Reconnecting; (2) a calm inline banner with the one-line action when not-reading for
> ~15 s; (3) optional local notification only for genuinely actionable states (BT
off, charge strap) — respect the DO-NO-HARM "never auto-interrupt" rule (no nagging;
on-demand + one calm banner). NO modal unless the condition is real and persistent.

DoD for Part C: with the strap off the wrist → "No signal" + "tighten the fit"; BT
off → "Bluetooth off" + "Turn on Bluetooth"; out of range → "Reconnecting…" + "bring
your strap closer" — each correct, calm, and actionable on a Release build.

---

## Suggested order
1. **B-RR** (unblocks the headline metrics) → 2. **Part C** (the contact/connection
coach the owner is frustrated about) → 3. **Part B** metrics through the derived
store → 4. **Part A** drag-drop + uniformity → 5. **B-HISTORICAL** backfill.
Log a status block at the end of each, like docs/18.
