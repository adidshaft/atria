schemaVersion: 1

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
