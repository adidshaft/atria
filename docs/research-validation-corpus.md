# External validation corpus contract

This is the admission contract for the P2 work in
`WHOOP_REMAINING_PRODUCT_GAPS.md`. It is intentionally a research workflow, not
a feature flag and not a way to generate a Recovery, stress, activity, sleep
stage, temperature, or SpO2 value in Atria.

Run the local validator before an offline evaluator receives any bundle:

```sh
python3 tools/validate_research_corpus.py corpus.manifest.json --output corpus.admission.json
```

An admitted result always says:

```json
{
  "research_only": true,
  "model_validated": false,
  "production_promotions": 0,
  "status": "admitted_for_external_evaluation_only"
}
```

The admission record is evidence that the dataset shape is safe to evaluate. It
is not evidence that a model is accurate enough to ship.

## Manifest shape

Use the per-consent pseudonym already present in an Atria research bundle. Do
not add names, device serials, free text, locations, or absolute dates.

```json
{
  "schema": 1,
  "research_only": true,
  "model_validated": false,
  "production_promotions": 0,
  "targets": ["GAP-10", "GAP-11", "GAP-12", "GAP-14"],
  "participants": [
    {
      "pseudonym": "participant-development-pseudonym",
      "split": "development",
      "bundle": {
        "digest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "schema": 4
      },
      "labels": []
    },
    {
      "pseudonym": "participant-held-out-pseudonym",
      "split": "held_out",
      "bundle": {
        "digest_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "schema": 4
      },
      "labels": []
    }
  ]
}
```

The empty arrays above make this a template, not an admissible corpus. Every
declared target needs time-aligned labels from both splits. A participant may
appear exactly once, in exactly one split.

## Label contracts

All `start_rel` and `end_rel` values use the bundle's schema-v4 day-zero axis.
They must not overlap within the same target series. Different targets may share
the same interval: for example, a PSG stage and an overnight-load reference
normally describe the same sleep window.

### GAP-10 — overnight physiological load

```json
{
  "gap": "GAP-10",
  "start_rel": 28800,
  "end_rel": 29100,
  "source": "research_protocol",
  "reference_level": 2,
  "coverage_fraction": 0.96,
  "qualified_rr": true,
  "motion_context": true,
  "hr_only": false
}
```

`source` must be `controlled_intervention`, `validated_questionnaire`, or
`research_protocol`. `reference_level` is the independently assigned 0–3
level from that documented protocol, not an Atria score. HR-only observations
cannot become a validation target.

### GAP-11 — activity type

```json
{
  "gap": "GAP-11",
  "start_rel": 36000,
  "end_rel": 36600,
  "activity_type": "walking",
  "label_source": "user_confirmed",
  "features": {
    "cadence": true,
    "orientation": true,
    "gyroscope": true,
    "hr_response": true
  }
}
```

The only admitted classes are `walking`, `running`, `cycling`,
`strength_training`, and `other_workout`. A type still cannot auto-save a
workout; participant-separated precision and recall must be reviewed first.

### GAP-12 — sleep stage

```json
{
  "gap": "GAP-12",
  "start_rel": 43200,
  "end_rel": 43500,
  "source": "polysomnography",
  "stage": "deep",
  "atria_derived": false
}
```

Only `polysomnography` or a named `defensible_reference` source is accepted.
An Atria hypnogram is never ground truth for its own validation.

### GAP-14 — sensor decoder pair

```json
{
  "gap": "GAP-14",
  "start_rel": 46800,
  "end_rel": 46860,
  "signal": "spo2",
  "reference_device": "named independent reference device",
  "pair_age_seconds": 1.2,
  "layout_stable": true,
  "negative_control": true
}
```

`signal` is either `skin_temperature` or `spo2`. The two signals may have
reference pairs for the same interval; repeated pairs for the same signal must
not overlap.

This admission check complements—not replaces—the held-out-day, reference-span,
bias, MAE, p95, correlation, and three-day requirements in
`14-spo2-skin-temperature-decoder-validation.md`.

## Review sequence

1. Build an opt-in Atria schema-v4 bundle and record its digest. Schema v4 is
   required for GAP-12 because it declares that Atria's own stage totals are
   not reference labels.
2. Create one sidecar row per external label, on the same relative timeline.
3. Admit the manifest with this tool; keep rejected data out of evaluation.
4. Train and assess only on `development` participants.
5. Calculate the documented target-specific metrics once on `held_out`
   participants.
6. Record the evaluator version, model version, thresholds, failures, and
   uncertainty in a review artifact.
7. Only after that review can a separately committed, versioned app model be
   considered. Historical values remain frozen under their prior model.

## GAP-11 and GAP-12 held-out reports

After the corpus has been admitted, an offline candidate model can be evaluated
against its complete, time-matched activity windows:

```sh
python3 tools/evaluate_activity_classifier.py \
  corpus.manifest.json activity.predictions.json \
  --output activity.held-out-report.json
```

`activity.predictions.json` has one prediction for every admitted GAP-11
window. It must keep `research_only: true`, `model_validated: false`, and
`production_promotions: 0`. `prediction` is one of the five scoped classes or
`unknown` for a deliberate abstention. The tool rejects missing, duplicate, or
unexpected windows, then reports confusion and per-class precision/recall from
**held-out participants only**. Development predictions are checked for
one-to-one alignment but do not enter those metrics.

The report status is always `held_out_metrics_for_review_only`. It is evidence
for a human model review, never an authorization to preselect, save, or
overwrite a workout type in the app.

The same evaluator accepts `--target-gap GAP-12` for sleep-stage candidates.
It reads only PSG or defensible-reference stage labels already admitted by the
manifest, measures wake/light/deep/REM precision and recall on held-out people,
and permits `unknown` as an explicit abstention. Atria-derived stage estimates
cannot enter the corpus and cannot become the evaluator's ground truth. Its
report has the same review-only status and cannot authorize a hypnogram, stage
typical range, or stage-weighted Recovery contribution in the app.

## GAP-10 held-out report

After a documented external protocol assigns its 0–3 labels, evaluate an
overnight-load candidate against the same complete windows:

```sh
python3 tools/evaluate_overnight_load_model.py \
  corpus.manifest.json overnight-load.predictions.json \
  --output overnight-load.held-out-report.json
```

The sidecar has a `prediction_level` (integer 0–3) for every admitted GAP-10
window. The report includes held-out mean absolute error, exact-level agreement,
level confusion, and level-3 precision/recall. It must remain
`research_only: true`, `model_validated: false`, and
`production_promotions: 0`; a passing command cannot turn on a production
overnight physiological-load score or feed the Sleep Score.
