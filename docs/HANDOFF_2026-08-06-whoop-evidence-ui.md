# Handoff — WHOOP-informed product completion (2026-08-06)

## Branch and scope

- **Working branch:** `codex/whoop-remaining-product-gaps`
- **Required integration target:** `codex/atria-reliability-handoff-2026-07-22`
- **Do not merge to `main`.**
- Source backlog: `docs/WHOOP_REMAINING_PRODUCT_GAPS.md` (currently an
  untracked, user-owned planning document; do not stage or replace it unless
  the owner explicitly asks).

This pass prioritized two product rules:

1. A chart must reveal a real decision from qualified evidence, not create a
   decorative or more certain-looking interpretation.
2. A user-facing score or label must reconcile to frozen inputs and must not
   rewrite history when defaults, profile values, or data quality change.

## Completed implementation checkpoints

The work below is committed on the working branch. The parenthetical commit is
the final checkpoint for that section; the log contains the smaller preceding
commits where a section was developed incrementally.

### P0 / P1 product correctness and UI

- **Frozen adaptive Sleep Need** — nightly need is frozen with the physiological
  cycle; old nights without trustworthy evidence stay missing rather than being
  recalculated. (`b3d16c45`, `d2e57cc3`)
- **Canonical Sleep Consistency** — schedule, score, contributors, trend and
  chart now share one evidence-qualified calculation rather than competing
  interpretations. (`1ec113a0`, `c175731f`)
- **HRR-based activity zones** — live targets, haptic transitions and completed
  activity zone distribution use frozen HRR BPM boundaries. (`b1d19432`,
  `c175731f`)
- **Recovery is morning-frozen** — naps feed a subsequent Sleep Need only and
  no longer inflate an already-issued Recovery. (`d2e57cc3`)
- **Truthful sleep presentation** — `Sleep stress` is now `Overnight HR load`;
  the card supports a Heart Rate / HR Load switch, preserves data gaps and
  shows an explicit unavailable state when archived evidence is absent.
  (`95fdef84`, `ffb0f659`, `c01d42b3`)
- **Sleep-stage honesty** — a saved sleep window with insufficient qualified
  motion/archived signal no longer pretends that stages are still processing;
  duration and available vitals remain visible while the hypnogram is
  explicitly unavailable. (`f7c9bbc1`, `a93b7ed7`)
- **Strength workflow** — persisted ordered supersets, transition/rest context
  and deterministic logged muscular-input receipts are present. The receipt is
  not yet fused into cardiovascular Strain. (`f50e3f7c`, `8cdc00e4`)
- **Recovery detail** — frozen, versioned contributor/input receipts support a
  transparent daily recovery explanation and prevent a later baseline change
  from rewriting the explanation. (`11627b4c`, `4d3974c4`, `9fe09400`)
- **Journal** — duplicate/repetitive surfaces were reduced; journal context is
  separated from recovery inputs and consented research data. (`3ecd5cbb`,
  `b577a752`)
- **Space and copy pass** — removed redundant outer shells from Live Monitor,
  Sleep detail and Morning Check-in. Live Monitor now has a distinct
  disconnected/baseline-building state instead of repeating “stress” at every
  hierarchy level. (`bf26d134`, `29456ab3`)

### Research and validation guardrails

- **External-label corpus gates** — schemas and validators now distinguish
  research/reference labels from Atria-derived output and enforce the correct
  signals, outcomes, provenance, and held-out participants. (`65fa04ef`,
  `e81d17ed`, `7fe6c267`)
- **Held-out evaluators** — offline evaluators exist for overnight HR load,
  activity classification, sleep stages, Recovery calibration and candidate
  temperature/SpO2 decoders. They report metrics only; none may promote a
  production model automatically. (`81a6e334`, `505d59eb`, `029210c5`,
  `59cd519a`)
- **Versioned export receipts** — research export is schema v6, containing
  frozen Recovery and muscular-input evidence while explicitly marking the
  latter as unfused. (`bb35c644`)

## Device verification completed

Use **iPhone Mirroring** for future visual checks; install/launch directly to
the attached device before reviewing. The latest device pass confirmed:

- App launches successfully after the v6 export work; no observed crash loop.
- Overview remains usable with incomplete strap history and labels the state as
  `Strap data gap — history incomplete`.
- The saved sleep state says `Sleep window saved`, not language implying that
  sleep-stage analysis is pending or complete.
- Sleep detail correctly shows unavailable sufficiency/efficiency/stages and
  overnight HR load when that specific saved window lacks archival evidence.
- Live Monitor’s stress baseline-build state uses a 0–3 scale and Heart Rate
  still exposes a clear timeline and Now/Average/Peak/Resting summary.
- The Recovery bottom sheet expands to the full detent without being obscured
  by bottom navigation.
- The removal of the giant outer containers in Live Monitor, Sleep detail and
  Morning Check-in is visually confirmed.

### Important interpretation for the currently attached device

An approximately eight-hour saved sleep window is **not** a completed stage
analysis. On this device, it was saved without usable archived HR/motion
coverage, so the correct display is duration plus an unavailable-evidence
state—not a hypnogram. This is not treated as a permanently stalled analysis.

Likewise, a partial strap-day with zero recovered steps must display `--`, not
`0` or `3% at 0`; `AtriaDailyStepPresentation` has that fail-closed rule.
Re-check this against a fresh install if the device shows a contradictory value.

## Required verification command sequence

Build and install from the current checkout (do not use a stale app bundle):

```sh
xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/atria-device build
xcrun devicectl device install app --device 00008130-000C74820130001C \
  /tmp/atria-device/Build/Products/Debug-iphoneos/Atria.app
xcrun devicectl device process launch --device 00008130-000C74820130001C \
  com.adidshaft.atria
```

Then inspect via iPhone Mirroring with the `computer-use` skill. Fetch a fresh
screenshot/state after every tap; the accessibility tree is sparse, so use
coordinate interactions only against the just-captured frame.

Do not accept research-sharing consent or upload/share health data during a
visual verification pass.

## Remaining work, in recommended order

### Must remain blocked pending external, consented reference evidence

These are deliberately **not** production features yet:

1. **GAP-10: validated overnight physiological-load/stress model.** Existing
   HR-load is a useful descriptive trace, but cannot be called a validated
   stress score or enter composite Sleep Score without reference outcomes.
2. **GAP-06: composite Sleep Score.** Do not produce one until all components,
   including GAP-10 overnight physiology, are independently qualified and the
   score is reproducible from frozen inputs.
3. **GAP-09: fuse muscular and cardiovascular Strain.** Logged muscular input
   is available, but the saturating fusion rule needs outcome-labelled
   calibration so it does not double-count cardiovascular work.
4. **GAP-11: automatic activity type classifier.** Requires participant-split,
   user-confirmed activity labels plus cadence/orientation/gyro/HR evidence.
5. **GAP-12: sleep-stage model validation.** Requires PSG or another defensible
   reference, split by participant. Never expose stages as EEG-measured.
6. **GAP-13: Recovery calibration.** Requires held-out fatigue, standardized
   performance, next-day HRV or RHR outcomes. Existing score stays versioned
   and transparent, not “validated.”
7. **GAP-14: temperature and SpO2 decoder validation.** Requires independent
   reference-device pairing, unit/range/placement/dropout analysis and
   repeated participants before any production reading.

The tools/docs are ready for these programs:

- `tools/validate_research_corpus.py`
- `tools/evaluate_overnight_load_model.py`
- `tools/evaluate_activity_classifier.py`
- `tools/evaluate_recovery_model.py`
- `tools/evaluate_sensor_decoder.py`
- `docs/research-validation-corpus.md`
- `docs/export-schema.md`

Baseline validation command:

```sh
python3 -m unittest \
  tools/test_validate_research_corpus.py \
  tools/test_evaluate_activity_classifier.py \
  tools/test_evaluate_overnight_load_model.py \
  tools/test_evaluate_sensor_decoder.py \
  tools/test_evaluate_recovery_model.py
```

The last run completed **37 tests, all passing**.

### Product/UI review still worth doing with more real history

- Re-check every trend after at least 1–2 weeks of qualified wear. Sparse
  history must show a useful building state, never fabricated interpolation,
  axes, or lines crossing data gaps.
- Review the Sleep consistency/history surface on-device. Keep the canonical
  schedule view only if it exposes actual bed/wake timing and a clear decision;
  remove any remaining opaque bar-strip rendition rather than restyling it.
- Exercise all strength superset flows on a device: create, reorder, ungroup,
  pause/resume and save. Check that logged muscular input is labelled as logged
  input—not total Strain.
- Recheck all unavailable states with deliberately partial/no wear: sleep
  detail, overnight HR load, steps, stress, Recovery contributors and activity
  zones. `--` is preferable to a numerical-looking placeholder.
- Continue the copy audit. Do not repeat “stress” in title, selector, subtitle,
  empty state and footnote when one precise explanation will do.

## Guardrails for the next implementer

- Work on a branch off `codex/atria-reliability-handoff-2026-07-22`; never use
  `main` as the source or integration target.
- Preserve frozen historical receipts. Fixes create new model versions or new
  cycles; they do not silently recompute history from today’s profile/baseline.
- Do not add unknown data as a neutral default, create synthetic chart points,
  or bridge a wearable gap with a line.
- Do not promote a research evaluator to production based only on passing unit
  tests. Unit tests validate the gate/tool, not the model.
- Do not stage `Atria/build-sim/` or the user-owned
  `docs/WHOOP_REMAINING_PRODUCT_GAPS.md` unless explicitly asked.

## Current checkpoint

`bb35c644 Export frozen muscular research receipts` is the last implementation
commit before this handoff. The handoff commit that follows records this paused
state; no merge has been made to `main`.
