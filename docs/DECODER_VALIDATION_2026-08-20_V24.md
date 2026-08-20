# WHOOP 4.0 V24 record decode validation — 2026-08-20 (read-only device evidence)

Validation of community-documented (openwhoop) field offsets against 37,086 real V24 records
pulled read-only from the installed app's historical archive (`rawPayloadHex` rows,
raw-v2 chunks of 2026-08-20, spanning 08-19 23:16 → 08-20 09:11 IST). Cross-refs: #31, #34,
docs/RESEARCH_BRIEF_2026-08-20_ACCURACY.md.

## Record shape observed

- All full-biometric records: `payload[0]=0x2f`, `payload[1]=0x18` (V24), length exactly 96 bytes.
- Stream byte `0x19` also present (397 records) — unidentified, not decoded here.
- No `0x0C` (V12) records on this strap/firmware.

## Anchor fields (validate the base offset) — CONFIRMED

| Field | Atria payload offset | Result on 37k records |
|---|---|---|
| unix seconds | [7:11] u32 LE | monotone, matches observedAt within drain latency |
| HR bpm | [17] u8 | 56–119, median 74 (plausible night/morning) |
| first RR ms | [19:21] u16 LE | ≈60000/HR within 200 ms for 89% of records carrying both |
| gravity xyz | [36:48] 3×f32 LE | median magnitude 1.015 g |
| skin contact | [51] u8 | 0 when off-wrist; 63–69 while worn |

## Skin temperature — field CONFIRMED, absolute scale NOT

- `[68:70]` u16 LE is a live thermal signal: night range 599–1129 raw, median 961; dips align
  with off-wrist/cooling; ≥100 whenever contact byte shows worn.
- The community ×0.04 °C scale yields median 38.4 °C — ~3–5 °C hot for wrist skin, consistent
  with openwhoop's own "empirical, may vary per device" caveat. Absolute °C stays blocked.
- **Relative deviations are fully usable now.** The existing pure relative-skin authority
  (blocker-first, baseline-of-qualified-nights) needs exactly this: a per-night raw-sample
  producer reading `[68:70]` from archive V24 rows. The prior `.incompleteArchive` deferral has
  aged out — 2026-08-19→20 alone holds 27,030 continuous 1 Hz records.

## SpO₂ — stays blocked, with a sharper reason

- `[64:66]` red / `[66:68]` IR decode as slowly varying DC levels (night: red 552–619,
  ir 671–736, stdev ≈11 counts). No pulsatile AC component exists at 1 Hz sampling.
- Ratio-of-ratios (110−25R) degenerates to a constant artifact: 286 candidate windows,
  median 80.1%, p25 79.9, p75 80.1 — that is correlated baseline drift (R≈1.2), not oxygenation.
  Shipping it would fabricate a number. #31's numeric SpO₂ block stands; the WHOOP strap
  computes SpO₂ internally from high-rate optical sampling these records do not carry.
- Unexplored: whether any other stream (e.g. 0x19) or a strap-side computed field carries the
  nightly SpO₂ result.

## Reproduction

Chunks pulled via `devicectl device copy from … Documents/atria-historical/segments/raw-v2/…`;
analysis is ~40 lines of python struct-unpacking over `rawPayloadHex` (see session transcript
2026-08-20). No app or strap state was modified.
