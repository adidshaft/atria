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

### A1. Trend graphs (Swift Charts)
Add real trend charts for the metrics users actually track over time:
- **Recovery**, **HRV (lnRMSSD)**, **RHR**, **Sleep duration/performance**, **Strain/day-load**.
- Ranges: **week / month / quarter** segmented (native `Picker(.segmented)`).
- Color each point/band by zone using the **electric palette** (recovery green/amber/red; strain electric blue).
- Show the **personal baseline band** (mean ± SD from `PersonalBaseline.lnRMSSDStats`) behind the HRV/RHR series so a point reads as "above/below my normal" — this is the WHOOP-style "is this good for *me*" framing.
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

## Part B — A 4th bottom-bar tab? (recommendation + caveat)

Current tabs: **Overview · Vitals · Data** (`HomeTab.overview/.vitals/.collection`,
`TabView` in `AtriaHomeView.swift:161`, native floating glass with
`.tabBarMinimizeBehavior(.onScrollDown)`).

**Recommendation: yes — add a "Trends" (or "Insights") tab, *if* Part A's graphs
grow past a couple of charts.** Rationale:
- The graph/history depth is genuinely user-facing and currently buried under the
  Overview's Today/**Trends**/Data sub-segment + a separate History view. Promoting
  it gives the charts room and removes the confusing overlap (a "Trends"
  sub-segment *and* a "Data" tab *and* a "Data" sub-segment exist today — untangle
  this).
- `Data` (backup/export/sensor signals) is genuinely a **power-user** surface;
  leave it, but it shouldn't be where a normal user looks for their week.
- 4 tabs is comfortable on iOS; keep the native floating-glass tab bar. Don't exceed 5.

**Caveat / decision gate:** if Part A only ships 1–2 charts, **don't** add a tab for
it — keep it as the Overview "Trends" sub-segment. A near-empty tab is worse than no
tab. Decide based on content volume, not aspiration.

**Alternative 4th tab if you go coaching-first instead of charts-first:** a **"Coach"**
tab (today's readiness verdict + recovery-scaled plan + journal). Pick *one* of
Trends-tab or Coach-tab; don't add both. Recommended order: Trends first (serves the
explicit "graphs" ask), Coach later.

---

## Part C — Higher-leverage user-facing features (from the research, ranked)

1. **Actionable coaching** — answer "what do I do about a 31% recovery?" (ReadinessEngine: ACWR/monotony already exist; surface a verdict + a recommended strain target + 1–2 concrete actions). Highest differentiator.
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
- **Recovery contributors (A2)** needs the per-term z exposed from `recoveryV2` — a small `AtriaAnalytics` change; keep the formula identical, only return the components.
- **Daily history persistence (A1)** is the prerequisite for trend charts and isn't there yet — design the rollup before the chart UI.
