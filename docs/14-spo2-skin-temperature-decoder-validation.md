# SpO2 and skin-temperature decoder validation

## Current status

Atria has no validated WHOOP SpO2 or skin-temperature decoder. Production
availability remains false, candidate observations remain research-only, and
no candidate value may be written to HealthKit or shown as a measured metric.

Historical record versions 12 and 24 contain changing little-endian fields at
payload offsets 64, 66, and 68. Their meaning is not established. In
particular, naming two fields “red” and “infrared,” treating their ratio as an
oxygen estimate, or dividing the third field to produce degrees Celsius would
all be unsupported assumptions.

## Reproducible replay

`tools/replay_sensor_reference.py` accepts complete `ATRIADBG frame` lines,
checks their declared length and WHOOP CRC framing, selects supported `0x2f`
records, and exports neutral fields:

- `raw_u16_64`
- `raw_u16_66`
- `raw_u16_68`
- `ratio_64_66` (a hypothesis feature, not a percentage)

Example:

```sh
python3 tools/replay_sensor_reference.py capture.log \
  --export-csv candidates.csv \
  --reference-csv reference.csv \
  --max-pair-age-s 2
```

For a copy-only device pull, `tools/pair_sensor_references.py` joins the
developer-mode CSV to the copied historical JSONL without decoding a metric:

```sh
python3 tools/pair_sensor_references.py reference.csv \
  <pull>/historical-archive-segments \
  --output-dir <new-empty-output-directory> \
  --window-seconds 2
```

It selects one nearest clock-qualified raw frame per reference, preserves the
original input/unit/notes and raw clock/layout provenance, reports the complete
archive time range, candidate counts, duplicates, rejected rows, and frame
reuse, and rejects malformed JSON or boolean numeric fields. Output remains
research-only and `not_validated`; a successful pair is not decoder validation.

Reference CSV shape:

```csv
timestamp,reference_spo2_percent,reference_skin_temp_c,label
2026-07-11T18:00:00.000,98.0,,seated-baseline
2026-07-11T18:00:01.000,,33.2,seated-baseline
```

Developer mode now exposes **Sensor references** in Research validation. Enter
the independent instrument reading and its model, measurement site, contact
state, condition label, and optional notes, then tap **Capture now** while that
value is visible. Atria assigns the phone timestamp at that tap. **Mark clock**
records a value-free synchronization event for aligning a simultaneous marker
in the independent instrument's export. The CSV begins with the four replay
columns above and appends this auditable context:

```csv
event_kind,reference_device,input_value,input_unit,measurement_site,contact_state,notes,local_only,research_only,decoder_validated,metric_promotions
```

Temperature input may be °C or °F; `reference_skin_temp_c` is always canonical
°C while `input_value` and `input_unit` preserve the operator's original entry.
Measured rows require a nonempty independent device model and measurement site.
Clock-marker rows contain no metric value. Every row explicitly exports
`decoder_validated=0` and `metric_promotions=0`; the capture workflow cannot
unlock a production metric.

Device logs and reference rows must use the same clock and timezone convention.
Naive timestamps are compared as wall-clock values. The output provides ranges
and exploratory correlations only and always emits `decoder_validated=0` and
`metric_promotions=0`. A correlation is not a decoder validation.

## Minimal return-to-device capture

Record the hardware model/generation, firmware revision, hardware revision,
record version, and payload length before each session. Do not include serial
numbers or other identifiers in shared artifacts.

Use a timestamped fingertip pulse oximeter for oxygen reference and a calibrated
contact skin-temperature probe positioned next to, but not over, the strap
sensor for temperature reference. A core or ambient thermometer is not an
equivalent skin reference. Record ambient temperature as context.

For each session:

1. Remove the charger, wear the strap snugly, foreground Atria, enable complete
   raw-frame logging, and synchronize the phone and reference clocks. Record a
   visible/manual marker in both streams.
2. Sit still for 10 minutes to establish on-body baseline and sensor settling.
3. Do light, ordinary exercise, then record 5–10 minutes of seated recovery to
   obtain safe natural oxygen variation. Do not use breath-holding, restricted
   breathing, high altitude, or any deliberate desaturation maneuver.
4. For skin temperature, record a second stable baseline, a mild safe warm
   condition, a mild safe cool condition, and recovery. Keep the contact probe
   adjacent throughout; avoid hot/cold extremes and direct ice or heat.
5. Record two-minute negative-control windows for off-wrist, loose contact,
   arm motion without exercise, and stillness. Label every transition to the
   second.
6. Preserve the raw log and independent reference CSV. Run replay without
   editing or selectively removing frames.

Repeat on at least three separate days. If the independent reference does not
span enough values to distinguish a sensor field from counters, timestamps,
motion, or contact-quality fields, the result is inconclusive rather than a
failed calibration.

## Evidence required before a generation-specific decoder

A decoder can be considered only when all of the following are present:

- Explicit device metadata proves the WHOOP hardware generation and firmware;
  a guessed generation or payload version alone is insufficient.
- At least 99% of frames in each tested session pass transport CRC and retain a
  stable record version, payload length, and candidate-field layout.
- Clock offset is measured with markers, and paired samples are no more than two
  seconds apart (or are resampled by a documented reference-device cadence).
- Candidate fields react consistently to the corresponding independent
  reference and do not behave like a sequence number, timestamp, motion field,
  contact flag, or fixed register.
- Model selection uses whole-session/day splits. Randomly splitting adjacent
  rows from the same maneuver is not independent validation.
- The SpO2 reference covers at least four percentage points. On held-out days,
  an engineering candidate should have absolute bias at most 1 percentage
  point, MAE at most 2 points, 95th-percentile absolute error at most 4 points,
  and correlation at least 0.8.
- The skin-temperature reference covers at least 2 °C. On held-out days, a
  relative-temperature candidate should have absolute bias at most 0.2 °C, MAE
  at most 0.3 °C, and correlation at least 0.9. Absolute skin-temperature claims
  require separate cross-day baseline validation.
- Corrupt, wrong-version, unknown-generation, off-wrist, and poor-contact input
  produces no numeric metric. There must be zero false metric promotions in the
  negative-control windows.
- The decoder is locked to the proven generation/firmware/layout and tested
  fail-closed for every other generation and record version.

These are conservative product engineering gates, not medical-device
certification. Passing them can justify further decoder review; it does not make
Atria or the reference instrument a diagnostic device.
