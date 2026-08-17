anonymousResearchSchemaVersion: 4
rawExportSchemaVersion: 1

# Atria Anonymous Research Bundle Schema

Core stance: your data stays yours; sharing is a GIFT — default OFF, inspectable
before it leaves, revocable anytime. This document describes the exact structure of
the anonymized research bundle, the anonymization rules that ensure no identifying
information leaves the device by construction, and the privacy properties that
underpin the consent model.

Implementation: `Atria/Atria/AtriaResearchBundle.swift` and enforced by the static
check `test_research_bundle_is_allowlist_and_denylist_clean` in
`test_handoff_static_checks.py`.

## File Format

Filename: `atria-research-<pseudonym-prefix8>-dayN.json.gz`

The bundle is JSON, gzip-compressed. Uncompressed size: varies, typically 1–20 MB
depending on data volume. Timestamps are JSON numbers (seconds since day-0 epoch).
All keys are alphabetically sorted in the JSON output.

## Consent and Pseudonym Lifecycle

**Granting consent:** When the user enables "Share anonymously with developers" in
Settings, the consent sheet (copy in `AtriaResearchConsentSheet`) must be reviewed
before the "I agree" button unlocks. Review requires opening the "see exactly what
leaves this phone" inspector, which builds a REAL bundle with a temporary pseudonym,
shows compressed size and SHA-256 digest, and displays a truncated pretty-printed
sample. The Agree button is **disabled** until the inspector is opened and returns a
non-zero byte count. Only then can the user press "I agree — share anonymously".

On "I agree", `grantConsent(previewPseudonym:)` executes:
- Sets `optIn = true`
- Adopts the temporary **pseudonym UUID** shown in the inspected bundle (stored
  as a string in UserDefaults), so the reviewed manifest is exactly the one a
  later manual or queued share uses
- Records the consent timestamp

**Revocation:** User toggles off in Settings → calls `revokeConsent()`:
- Sets `optIn = false`
- **Destroys the pseudonym UUID** (removed from UserDefaults)
- Clears the consent timestamp

**Unlinkability:** After revocation, if the user re-consents, a **fresh pseudonym**
is generated. No future share can be linked to any prior share — the UUID is the
sole linking key, and it is destroyed on revoke.

## Top-Level Structure

The bundle is a JSON object with these keys:

```
{
  "manifest": Manifest,
  "sessions": [Session, ...],
  "sleeps": [Sleep, ...],
  "workouts": [Workout, ...],
  "days": [Day, ...],
  "journal": [JournalAnswer, ...]
}
```

## Manifest

User profile snapshot and bundle metadata:

```typescript
{
  "schema": 4,                      // integer, always 4 for this schema version
  "pseudonym": "UUID",              // string, 36-char UUID (e.g., "550e8400-e29b-41d4-a716-446655440000")
  "appVersion": "string",           // e.g., "1.0.2"
  "ageBand": "N-M" or "unknown",    // age band (e.g., "30-34"); see Banding rules below
  "weightBandKg": "N-M kg" or "unknown",  // weight band
  "heightBandCm": "N-M cm" or "unknown",  // height band
  "biologicalSex": "male"|"female"|"other"|"prefer_not_to_say"
}
```

**ageBand math:** `floor(age / 5) * 5` to `floor(age / 5) * 5 + 4`. Example: age 34
→ "30-34". If birth year is missing or invalid (≤ 1900), returns "unknown".

**weightBandKg and heightBandCm:** Same banding formula, 5-unit width. Example: 76.2
kg → "75-80 kg". If the measurement is ≤ 0, returns "unknown".

## Sessions

Raw physiological recordings from saved sessions. Each session is a continuous
capture of heart rate and RR interval series.

```typescript
{
  "startRel": double,       // seconds since day-0, relative epoch (e.g., 120.5)
  "endRel": double,         // seconds since day-0
  "kind": "session"|"sleep"|other,  // string, activity kind (usually "session" or source)
  "hrPoints": [[tRel, bpm], ...],   // array of [day-0 time, heart rate] pairs
  "rrPoints": [[tRel, ms], ...],    // array of [day-0 time, RR interval in ms] pairs
  "motionEpochs": [MotionEpoch, ...], // bounded day-0-aligned motion features
  "restingStable": integer,         // count of resting-HR-stable samples (0–100 range expected)
  "hrv": integer or null            // heart-rate variability (ms), optional
}
```

**Time precision:** `rel(date) = round(date.secondsSince(epoch0) * 10) / 10`.
Times are rounded to 0.1-second precision.

**hrPoints:** Each point is `[tRel, bpm]` where `tRel` is seconds since day-0 and
`bpm` is an integer heart rate in beats per minute. A point's timestamp is exactly
`rel(session.start + secondsFromSessionStart)`. Malformed points outside the saved
session interval are omitted rather than clamped or reconstructed.

**rrPoints:** RR intervals (beat-to-beat intervals) in milliseconds. Times use the
same day-0 axis as `startRel`, `endRel`, `hrPoints`, and `motionEpochs`. If no RR
data was captured, this array is empty.

### MotionEpoch

Only bounded features from independently recovered gravity evidence are included.
Raw IMU frames, location, device identifiers, and free text never leave the phone.
Each epoch is clipped to its owning session before export, so it shares the same
day-0 axis as HR/RR points.

```typescript
{
  "startRel": double,
  "endRel": double,
  "rows": integer,
  "validatedRows": integer,
  "stillnessRatio": double|null,
  "movementIntensity": double|null,
  "p95VectorDelta": double|null,
  "maximumGapSeconds": integer,
  "measurementValidated": boolean,
  "lowMotionQualified": boolean,
  "source": "historical_gravity_recovered_epoch_v1"
}
```

**restingStable:** Counter of how many HR samples were stable enough to be included
in the resting-HR baseline. Integer, 0–100 typical range.

**hrv:** Heart-rate variability, typically in the range 20–100 ms for healthy
individuals. Null if not computed or not available for this session.

## Sleeps

User-confirmed sleep records with optional stage breakdowns.

```typescript
{
  "startRel": double,               // seconds since day-0
  "endRel": double,                 // seconds since day-0
  "durationS": double,              // total duration in seconds (e.g., 28800 = 8 hours)
  "confidence": "high"|"medium"|"low"|"unknown"|"...",  // string, user confidence or source
  "stageProvenance": "atria_derived_research_only_not_reference",
  "stageReferenceEligible": false,
  "stageSeconds": {
    "light": double,                // seconds in light sleep
    "deep": double,                 // seconds in deep sleep
    "rem": double,                  // seconds in REM sleep
    ...                             // other stages as reported
  }
}
```

**stageSeconds:** A map of Atria-generated sleep-stage names to duration in
seconds. It may contain `light`, `deep`, `rem`, or `awake`, and is empty `{}` if
no stage breakdown is available. Durations are aggregated from Atria stage
segments. `stageProvenance` is always
`atria_derived_research_only_not_reference` and `stageReferenceEligible` is
always `false`: this field is never PSG, never an independent reference, and
must not be used as a training or validation target for sleep staging.

## Workouts

User-confirmed workout records.

```typescript
{
  "startRel": double,               // seconds since day-0
  "endRel": double,                 // seconds since day-0
  "activityType": "string",          // canonical picker value, e.g., "Running"
  "labelSource": "user_confirmed",   // never an automatic classification
  "avgHR": integer,                 // average heart rate during workout
  "peakHR": integer                 // peak (maximum) heart rate during workout
}
```

**activityType:** An allowlisted canonical picker value resolved from the user's
confirmed activity. The free-text workout title is never exported.

**labelSource:** Always `"user_confirmed"`. This bundle can support future
evaluation, but it does not claim an automatic activity classifier exists.

## External-validation corpus admission

`tools/validate_research_corpus.py` is the fail-closed admission gate for any
offline research corpus built from these bundles. It consumes a separate,
local-only manifest of pseudonymous bundle digests and time-aligned external
labels; it does not upload data, train a model, or promote an app metric.

Every declared target must have both `development` and `held_out` participants,
and no pseudonym may appear in both. The manifest rejects HR-only
overnight-load labels, non-user-confirmed activity labels, Atria-generated sleep
stages as references, and sensor pairs without stable layouts, negative controls,
or two-second clock alignment. It also rejects any attempted model validation or
production promotion.

Successful validation emits only `admitted_for_external_evaluation_only` with
`model_validated: false` and `production_promotions: 0`. A separate review of
held-out metrics is required before a versioned production model can exist.

For GAP-11, `tools/evaluate_activity_classifier.py` consumes an admitted corpus
manifest and a local prediction sidecar. It requires a prediction for every
admitted activity window, measures only held-out participants, and emits
per-class precision/recall and a confusion matrix under
`held_out_metrics_for_review_only`. With `--target-gap GAP-12`, it applies the
same rule to PSG/defensible-reference sleep-stage labels. It cannot validate or
promote either model.

For GAP-10, `tools/evaluate_overnight_load_model.py` requires a documented
external `reference_level` and matching local 0–3 candidate predictions. It
reports held-out calibration and level-3 classification metrics only; it cannot
enable the physiological-load model or contribute to Atria Sleep Score.

For GAP-14, `tools/evaluate_sensor_decoder.py` evaluates temperature and SpO2
as separate candidates against independent reference values and negative
controls. It reports held-out error, correlation, span, session coverage, and
false promotions, but does not enable a decoder.

For GAP-13, schema-v5-and-newer research bundles carry only frozen, versioned Recovery
receipts. `tools/evaluate_recovery_model.py` compares a candidate version with
pre-registered external outcomes on held-out participants; it cannot rewrite
stored scores or approve a Recovery model.

## Days

Daily metric rollups (aggregates used for charts and context).

```typescript
{
  "dayIndex": integer,              // 0 = earliest day, 1 = next day, etc.
  "recoveryPercent": integer or null,  // 0–100, null if not available
  "strain": double or null,         // typically 0–21, null if not available
  "sleepHours": double or null,     // hours of sleep that night/day
  "restingHR": integer or null,     // resting heart rate (bpm)
  "hrv": integer or null            // heart-rate variability (ms)
}
```

**dayIndex:** Integer count, 0-indexed. The day containing `epoch0` (the start of
the earliest recorded day) is day 0. Day 1 is the next calendar day, etc.

**recoveryPercent:** A 0–100 score indicating readiness. Null if recovery was not
computed (e.g., insufficient baseline, no sleep data).

**strain:** A continuous score, typically 0–21 (WHOOP-style). Null if not computed.

**sleepHours:** Total sleep duration for the calendar day, in hours. Computed from
confirmed sleep records ending on that day. Null if no sleep was recorded.

**restingHR:** Resting heart rate, in bpm. Null if not available.

**hrv:** Heart-rate variability, typically 20–100 ms. Null if not available.

## Journal Answers

User-entered responses to typed journal questions (optional feature).

```typescript
{
  "questionID": "string",           // e.g., "alcohol", "mood", "stress"
  "dayIndex": integer,              // calendar day (0-indexed from epoch0)
  "kind": "boolean"|"timeOfDayMinutes"|"quantity"|"scale1to5",  // response type
  "value": double or null           // numeric encoding of the answer
}
```

**kind and value encoding:**
- `"boolean"`: value = 1 (yes) or 0 (no)
- `"timeOfDayMinutes"`: value = minutes since midnight (0–1440)
- `"quantity"`: value = count or measurement (e.g., glasses of water)
- `"scale1to5"`: value = rating 1–5

If the user did not answer a question on a given day, no entry is present in the
journal array for that day.

## Time Model: Day-0 Relative Epoch

**Epoch definition:** The epoch0 is the start of the calendar day (00:00:00) of the
earliest date in the bundle:

```
epoch0 = startOfDay(min(
  all session start dates,
  all sleep start dates,
  all workout start dates,
  all daily metric dates,
  all journal-answer days
))
```

**Relative time computation:**

```
rel(date) = round(date.secondsSince(epoch0) * 10) / 10
```

Times are stored as seconds since epoch0, rounded to 0.1-second precision.

**What is preserved:**
- Time-of-day (e.g., 14:30 UTC is preserved relative to epoch0, if the device is
  in UTC)
- Duration (e.g., a 1-hour session remains 3600 seconds)
- Day spacing (e.g., if session 2 starts on day 5, dayIndex = 5 in the Days array)
- Within-day sequence (e.g., morning sleep then afternoon workout is preserved)

**What is destroyed:**
- Absolute calendar dates (no ISO-8601 dates in the bundle)
- Year, month, day numbers
- Timezone (the relative epoch is anchored to device local time at capture; no
  timezone field is included)
- Clock drifts or absolute-time semantics (the bundle is a relative timeline,
  immune to device-clock adjustments)

**Day-index math:**

```
dayIndex(date) = dateComponents([.day], from: epoch0, to: startOfDay(date)).day
```

Example: If epoch0 is 2026-06-01 and a metric is for 2026-06-05, then dayIndex = 4.

## Banding Rules

Age, weight, and height are banded (grouped into ranges) to reduce identifiability
while preserving enough information for research.

### Age Banding

```
ageBand(yearOfBirth) =
  age = currentYear - yearOfBirth
  lower = floor(age / 5) * 5
  return "{lower}-{lower+4}"
```

Example: age 34 → "30-34". Age 35 → "35-39".

Special cases: If `yearOfBirth` is missing or ≤ 1900, returns "unknown".

### Weight and Height Banding

```
band(value, width, unit) =
  if value <= 0: return "unknown"
  lower = floor(value / width) * width
  return "{lower}-{lower+width} {unit}"
```

Width is 5 for both weight and height.

Examples:
- weight = 76.2 kg, width = 5 → "75-80 kg"
- height = 180.0 cm, width = 5 → "180-185 cm"
- weight = 0 or negative → "unknown"

## Explicit Denylist

The following identifiers are **never** included in the bundle. The static check
`test_research_bundle_is_allowlist_and_denylist_clean` asserts that these tokens
never appear in the research-bundle encoder:

- `deviceName` — device model or name
- `faceOffDisplayName` — watch display name or custom device name
- `strapName` — strap/band identifier
- `TimeZone.current` — device timezone
- `birthYear:` — absolute year of birth (only age band is included)

Any field not explicitly modeled in `AtriaResearchBundlePayload` is excluded by
construction.

## Schema Version and Upgrade Path

**Current anonymous research bundle version:** 3

**When to bump the version:**

1. **Add a field to any struct** (e.g., add `lactateThreshold` to Day) → version
   bump required.
2. **Change the type of an existing field** (e.g., `hrPoints: [[Double]]` to a new
   format) → version bump required.
3. **Add a new top-level array** (e.g., `bloodPressure: [BloodPressure]`) → version
   bump required.
4. **Rename a key** (e.g., `dayIndex` → `dayNum`) → version bump required.
5. **Change the time-to-seconds conversion formula** (e.g., rounding precision or
   epoch definition) → version bump required.

**What does NOT require a version bump:**

- Adding values to an open enum (e.g., new sleep stages or journal kinds) — old
  decoders silently ignore unknown values.
- Changing an optional field from null to a value (backward compatible if decoder
  is lenient).
- Adding items to an array (e.g., more journal answers) — same array type, no
  format change.

**Upgrade strategy:** Future versions should follow a two-step deprecation:

1. A new version introduces a new field, renamed key, or changed temporal contract.
2. The encoder emits only one explicit version; receivers must reject a version
   whose contract they do not understand rather than silently guessing.
3. Version 3 is the first version with one day-zero-relative timeline across
   sessions, HR/RR points, motion epochs, workouts, daily rows, and journal rows.

## Allowlist and Transparency

Every field in the bundle is deliberately chosen and documented here. Any field NOT
listed above is excluded by construction — it cannot leak.

The static check `test_research_bundle_is_allowlist_and_denylist_clean` enforces:

- Presence of required consent and schema infrastructure (enum `AtriaResearchSharing`,
  struct `AtriaResearchBundlePayload`, `grantConsent`, `revokeConsent`, pseudonym,
  ageBand, consent-gate `.disabled(!hasInspected)`).
- Absence of denylist tokens (deviceName, faceOffDisplayName, strapName,
  TimeZone.current, birthYear:).

This is the **reviewable source of truth** for what Atria's research sharing exports.

## Honesty Caveats

### High-resolution heart-rate series are quasi-identifying.

The bundle includes **every accepted HR sample** from recorded sessions. The
time-of-day, resting-HR baseline, HRV values, and shape of the HR response to
activity are **unique to an individual**. Even without names or device
identifiers, a trained analyst with independent HR data could potentially
re-identify the person.

The consent sheet includes the honesty line: *"Note: detailed heart data is unique
to you; we strip identifiers, but patterns in the data itself are inherently
yours."* Researchers and the developers MUST NOT overpromise anonymity; the bundle
is pseudonymous (identified only by a random code), not anonymous in the
cryptographic sense.

### Other quasi-identifiers:

- **RR intervals (beat-to-beat variability):** Similar quasi-identifying risk to HR
  series.
- **Sleep stage timing and duration patterns:** Individual-specific, especially with
  multiple nights of data.
- **Workout intensity and duration patterns:** Combined with HR response, can
  narrow identity across a cohort.
- **Age band + weight band + height band + biological sex:** With sufficient
  demographic data, the combination of bands reduces uniqueness within a population.

### Mitigation:

- Pseudonym UUID is destroyed on revoke, ensuring no persistent linkage.
- Timestamps are relative (day-0 epoch), preventing cross-correlation with external
  calendar events.
- All identifiers (names, devices, timezone) are stripped.
- Research use of the bundle must comply with the consent scope: algorithm
  improvement for recovery, sleep, and strain. Other uses (re-identification
  research, sale, secondary research without re-consent) are out of scope.

## Compression and Transport

The bundle is JSON, gzip-compressed. Filenames follow the pattern:

```
atria-research-<pseudonym-prefix8>-dayN.json.gz
```

Example: `atria-research-550e8400-day42.json.gz`

The first 8 characters of the pseudonym UUID are shown in the filename (not the full
UUID, for brevity). The maximum day index in the Days array is appended as `dayN`.

A daily opted-in upload uses the same gzip JSON bytes under this anonymous
object key (pseudonym prefix + civil day of the upload, no name, email, or
device identifier):

```
anonymous/<pseudonym-prefix8>/<YYYY-MM-DD>.json.gz
```

Example: `anonymous/550e8400/2026-08-17.json.gz`

The default local clock is 03:00; Settings persists a custom hour:minute as
`atria.dataSharing.dailyUploadMinutes`. The iOS app stays local-first and only
enqueues the bundle; `tools/upload_anonymous_daily.py` is the AWS CLI put/head
entry (`aws s3 cp` / `aws s3api head-object`) against the configured bucket
(`ATRIA_ANONYMOUS_RESEARCH_BUCKET` or the shipped default).

Transport is also available manually via ShareLink. Each share is
recorded in a 20-entry local ledger with:

```
<ISO8601 timestamp>|<SHA256 digest prefix 12 chars>|<compressed bytes>
```

Example:

```
2026-07-04T14:30:00Z|a1b2c3d4e5f6|2048512
```

This ledger is shown in Settings under "Last bundle" and persisted locally for the
user to review.

## Validation and Testing

The `AtriaAnonymousDailyUploadScheduleTests.swift` suite drives the shipped
due/not-due function from a clean defaults start: unset time is 03:00 local, a
stored custom time is the one used, 02:59 is not due, 03:00 is due once, a
second call the same local day is not due, and opted-out is never due.

The `AtriaResearchSharingTests.swift` suite validates:

- Consent lifecycle (grant, revoke, re-consent generates fresh pseudonym).
- Banding math for age, weight, height.
- Builder-level temporal alignment: every emitted timestamp/index is non-negative;
  HR/RR points, motion epochs, workouts, and journal rows share one day-zero axis.
- Payload contains no ISO-8601 dates, deviceName, displayName, birthYear, or
  timezone.
- Receipts ledger caps at 20 entries, newest first.
- Session, Sleep, Workout, Day, and Journal answer structures encode and decode
  correctly.

The static check enforces the denylist and required consent infrastructure.

## Security Properties

1. **Pseudonym isolation:** The pseudonym is a random UUID per consent grant,
   destroyed on revoke. No device-persistent secret links shares across time.
2. **Explicit contracts:** Schema version 6 is the current anonymous research
   contract. Future versions will be declared here before a changed bundle ships.
3. **Unmodifiability:** The bundle is a static JSON file, hashable. SHA-256 digests
   are recorded in the local ledger to detect mutation or corruption in transit.
4. **Opt-in default:** Sharing is OFF by default. No bundle is built or sent unless
   the user explicitly grants consent and reviews the contents.

---

# Atria Raw Export Schema

All timestamps are Unix milliseconds in UTC. CSV files are ASCII, newline-terminated,
and use numeric columns only.

## hr.csv

`unix_ms,bpm`

Every accepted heart-rate sample from saved sessions.

## rr.csv

`unix_ms,rr_ms`

Raw accepted RR intervals from saved sessions, before any correction.

## sleeps.json

Array of user-confirmed sleep records, including source, confidence, and optional
stage segments.

## workouts.json

Array of user-confirmed workout records plus any saved session strength sets.

## rollups.json

The daily rollup entries Atria uses for charts and context, including optional
nutrition context when present.
