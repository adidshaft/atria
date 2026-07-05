# docs/25 — Remaining Work: Full Implementation Specs

Date: 2026-07-06. State as of commit `db3d60d6` (see docs/24 §26 for what already
shipped). Every user directive through 2026-07-05 is implemented, gated
(128/128 static checks, full unit suite, Release install), and field-verified.
This document specifies **everything that remains**, in enough detail to
implement without re-derivation. Items are grouped by what unblocks them.

Gates for ALL items (non-negotiable):
- `python3 test_handoff_static_checks.py` → OK (0 failures; migrate pins you
  displace with dated comments)
- `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -destination
  "generic/platform=iOS Simulator" build` → BUILD SUCCEEDED
- Full unit suite on sim `51BECE0B-0745-4808-B033-6D6D8A39DC33` → TEST SUCCEEDED
- Visual work: sim fixture loop (`--atria-developer-mode
  --atria-complete-onboarding --atria-ui-fixture north-star-highlights
  --atria-ui-screen <screen>` + `simctl io screenshot`, READ the png).
  Views unreachable headlessly: temporary UIHostingController+drawHierarchy
  XCTest, deleted after. NEVER diagnose colors from nighttime device captures
  (Always-On Display flattens them — docs/24 §23).
- Honesty rules are law: no fabricated data, confidence tiers, learning
  placeholders, fail closed where product-correct.

---

## A. Blocked on a user decision (say the word and these start)

### A1. ATRIA Intelligent Assistant v1 (on-device Q&A) — effort L
The Assistant tab ships as "Coming Soon". V1 needs **no network and no LLM**:
a deterministic intent router over data the app already computes.

Spec:
- New `Atria/Atria/AtriaAssistant.swift`:
  - `enum AssistantIntent`: `recoveryWhy`, `sleepSummary(day: Date?)`,
    `strainVsTarget`, `hrvTrend`, `rhrTrend`, `compareWeek`, `whatIsMetric(AtriaTodayMetric)`,
    `improveMetric(...)`, `unknown`.
  - `AssistantIntentParser.parse(_ text: String) -> AssistantIntent` — keyword
    table + synonyms ("why is my recovery low/bad" → recoveryWhy; "how did I
    sleep [yesterday/Tuesday]" → sleepSummary; "am I overtraining" →
    strainVsTarget+load). Pure, unit-testable.
  - `AssistantAnswerer.answer(intent:store:) -> AssistantAnswer` — composes
    from EXISTING sources only: `displayHero`/recovery contributors,
    `SleepHistorySnapshot`, `DailyRollupStore` medians (reuse
    `AtriaHistoryModel.medianWindow`), `Coach.guide` narrative,
    `AtriaFitnessAge.factors`, education copy from the vitals sheets.
    `AssistantAnswer { text: String, confidence: String, relatedMetric:
    AtriaTodayMetric?, followUps: [String] }` — confidence line is mandatory
    ("based on your hr_only sleep last night").
- Chat UI in the existing tab: message list (user bubble / atria card),
  suggestion chips seeded from `followUps`, input bar. Liquid Glass tokens.
  Tapping `relatedMetric` opens the existing metricDetail sheet.
- Honesty: `unknown` intent answers honestly ("I can answer about your
  recovery, sleep, strain, trends…") — never fabricates.
- Tests: parser table-driven (≥20 phrasings), answerer fixtures (recovery low
  because RHR elevated / HRV suppressed / sleep short — assert each
  contributor sentence appears).
- Future LLM upgrade path: keep `AssistantAnswerer` behind a protocol so a
  foundation-model backend can slot in without UI change.

### A2. Sharing upload server + transport — effort M (server S, app S)
Bundles queue in `Application Support/research-outbox` (7-day retention,
foreground catch-up in place). Missing: a real POST target.

Spec:
- Server: Cloudflare Worker `PUT /v1/bundle/<pseudonym8>/<date>` → R2 bucket;
  auth via a static bearer token embedded per-build (rotate by release);
  responds 201; no read API (write-only drop box). ~40 lines of Worker JS.
- App: `AtriaResearchUploadQueue.enqueueAndAttemptTransport` already funnels
  everything; implement the transport there: URLSession upload of the .gz,
  2xx → delete outbox file + recordReceipt(sent). Endpoint from
  `atria.research.endpointURL` (Settings row exists).
- **Requires lifting the local-first network ban**: static check
  `test_local_first_core_has_no_network_or_browser_clients` bans URLSession
  app-wide. Decision needed: scope an allowlist exemption for exactly
  `AtriaResearchBundle.swift` (check rewritten to assert URLSession appears
  ONLY there), and update `docs/export-schema.md` + App Store privacy labels.
- Tests: transport mocked via URLProtocol; 2xx deletes, 5xx retains with
  backoff stamp; revoke mid-flight cancels.

### A3. Face-Off web fallback publish — effort S (user action + 1 commit)
`docs/pages/faceoff/index.html` is ready (DecompressionStream deflate-raw).
Steps: enable GitHub Pages on the repo (docs/ folder), set the final URL in
`AtriaFaceOff.swift` `webFallbackBase`, add the AASA snippet from
`docs/pages/README.md` when a custom domain exists. Then Face-Off links opened
by non-Atria users render in the browser.

### A4. Duty-cycle default-ON flip — effort S, criteria-gated
Power saver is OFF by default (`atria.dutycycle.enabled`). Flip when Gate E
criteria hold: 3 consecutive days with (a) sparse-mode daytime coverage gaps
never spanning a workout candidate (check `duty_cycle` + workout logs), (b)
battery delta improvement ≥15%/day vs full capture, (c) zero
`sparse_expected_silence` misclassifications during wear. Flip =
`DutyCycleDefaults.enabled` default true + onboarding mention + docs/24 note.

---

## B. Time/data-gated (they resolve themselves — just verify)

### B1. Archive compaction first live run (~mid-July)
The 158 MB archive's rows age past 30 days around 2026-07-15. The daily driver
will fire (50k-row threshold met). VERIFY on the day: `archive_compaction_last_run_at`
advances, `historical-archive.jsonl` shrinks to per-minute summaries +
pinned confirmed windows, `metric_ready=1` stays, green invariant holds
(`aborted_green_invariant` absent from logs). Rollback: restore from the
pre-compaction sidecar it writes.

### B2. Overview advice card (needs ≥1 real journal insight)
`journalInsightsCache` gains entries once journal answers accumulate (2–3
weeks of typed answers). When non-empty: surface the top insight as an
Overview card (reuse `AtriaJournalTab` Patterns row rendering; place after
highlights). Honest gate: only `confidence != .low` insights.

### B3. Charge-pattern nudge validation (needs ~5 charge observations)
`ChargePatternDefaults.hours` fills as the user charges. Once ≥5 entries:
verify the reminder fires only in the ±1h median window, <30%, 20h cooldown
(`notification_skip kind=fit_check` ledger + scheduled entries).

### B4. Deep/SWS calibration (needs reference nights)
Display fold shipped (SWS+Deep = one honest "Deep"). True threshold
calibration needs ≥5 nights with an external reference (user's old WHOOP
exports or Apple Watch). Then: tune `stage()` HR-delta cutoffs
(AtriaSleepWakeResearch.swift:174-175) to minimize stage disagreement;
keep the 5-case taxonomy (persisted data).

### B5. Nightly sharing BG-task window (needs one undisturbed night)
Foreground catch-up guarantees a daily bundle post-opt-in regardless; still
verify `research_upload status=ok reason=bg_processing` fires naturally on a
night without installs. If iOS never grants it in 3 undisturbed nights,
accept catch-up as primary (no code change needed).

---

## C. Technical follow-ups (unblocked, medium value — good loop fodder)

### C1. Consolidate the dual Today layout systems — effort M, HIGH value
Two sources of truth govern Today (docs/24 §25): `AtriaTodayMetric` order/
hidden CSVs AND `AtriaHomeLayoutConfig.glanceMetrics` (cap 14). Every change
must touch both or silently no-ops — it already caused one shipped bug.
Spec: make `AtriaHomeLayoutConfig.glanceMetrics` THE source; derive the
Customize sheet from it; migrate `AtriaTodayMetric.orderStorageKey`/hidden
CSVs into it once on launch (one-time migration, remove legacy keys); delete
`ordered(from:)`/`visibleOrdered` after migrating their tests. Heavy pin
migration expected — budget for ~10 static-check needle updates.

### C2. hrRRMismatch counter population — effort S
`SavedSession.hrRRMismatch` is plumbed but always 0. Populate at
`AtriaBLEManager.swift:3394` (finalize path) from the existing RR-implied-vs-
reported disagreement counter (per-frame `>30bpm` test at ~:7469). Then the
workout hardening's RR-agreement ceiling gets its per-session signal even for
historical sessions.

### C3. History surface wiring gaps — effort S
- `detectedCount` hero chip: wire to real signal = count of days whose
  `latestWorkoutReviewCandidate` fired but was never confirmed (needs a small
  persisted counter bumped in the candidate path; honest 0 until data).
- `reviewPending` chips: wire to the live review-candidate state for today
  (same source as the Overview review card).

### C4. Chip-fill token migration + Radius.concentric — effort M, cosmetic
~50 ad-hoc `.background(color.opacity(x), in: RoundedRectangle(...))` chips
in AtriaOverviewSections; `Radius.concentric(parent:inset:)` defined but
unused (nested corners not mathematically concentric). Do as ONE sweep with
before/after sim screenshots per screen; pure-visual, low risk, needs eyes.

### C5. Instruments corroboration pass — effort S, daytime with user
Body-probe counters are wired (`AtriaBodyEvalProbe`); the missing evidence is
a Time Profiler capture during REAL interaction (autoscroll fixture doesn't
generate scroll churn headlessly). Protocol: user scrolls Today/Vitals 30s
while `xcrun xctrace record --template "Time Profiler"` attaches; confirm
`AtriaTodayScreen.body` and `Array.sorted` absent from the hot path.

### C6. Live workout completeness audit — effort S (verify) + gaps
Parity matrix item: verify `AtriaLiveWorkoutView` end-to-end — zone ladder
updates live, strain-to-target progresses, haptic zone alerts fire
(`AtriaHapticAlerts`), Live Activity/Dynamic Island reflects state, workout
save flows to confirmation. Fix whatever the audit finds; fixture
`--atria-ui-fixture live-workout-*` variants exist.

### C7. Cycle tracking phase 2 — effort M, after user opts in
Current v1: manual period logging + phase estimate + one coach line. Phase 2:
skin-temp-informed phase refinement (bodyTemp deltas already computed),
phase overlay on trend charts (background bands), optional phase-aware
notification ("luteal week: expect higher RHR").

### C8. Monthly report surfacing — effort S
`AtriaMonthlyReport` exists behind the Week/Month toggle. Add: month-end
notification (kind `monthly_report`, budget-aware) + a History-hero link the
first 3 days of a new month.

---

## D. WHOOP-parity long tail (from the researched matrix, descending value)

1. **Healthspan-style factor breakdown** — `AtriaFitnessAge.factors` already
   computes four contributors; render them as rows with per-factor trend
   arrows on the Health screen (S).
2. **Nap credit surfacing** — math is wired and tested; add the UI line
   "‑38m need from today's nap" on the sleep detail + plan card (S).
3. **Behavior-impact expansion** — more journal factors (late meals, screens)
   into `AtriaBehaviorImpact`'s existing p-value engine (S each).
4. **Multi-friend Face-Off** — bracket of stored cards; low priority, no
   accounts ever (M).
5. **Stress Monitor v2** — add a daily stress timeline strip (samples exist
   in the store's stress state history once persisted — persist 1/5min) (M).

---

## E. Standing constraints (do not regress)

- Static checks and unit suite are REAL gates at zero failures now.
- Steps stay honest-dead ("Not available on this strap") unless IMU decode
  ever lands (protocol research parked — docs/18).
- No reconnect-logic variants (strap-side stalls); watchdog resets stay paced
  (30s min / 10-min backoff after 3 ineffective).
- No installs during the user's sleep window (protects overnight validation
  + BG task scheduling).
- Model tiering: Opus/high thinks (specs, judgment), Sonnet implements,
  Haiku for mechanical work.
- Two-layout-system gotcha until C1 lands: change BOTH or it doesn't ship.
