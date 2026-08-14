# 16 — Metric Authority & Confidence Policy

Status: **binding engineering policy** (WP-0 of the full-replacement directive)
Anchored in code by the `MetricAuthority` block in `Atria/Atria/Metrics.swift`
and pinned by `AtriaMetricAuthorityGuardTests`.

## The honesty rule

No fabricated data. Estimates are labeled estimates. Confidence tiers stay
honest. Missing evidence produces a gap, a limited-confidence label, or no
score — never a silently invented value.

(Some older tests cite this as the "docs/24 honesty rule"; this document is the
durable docs/ anchor for that rule.)

## Adding a new metric — mandatory declarations

Any new user-facing metric (or promotion of an existing research value to a
product surface) must declare, in code and in its PR description:

1. **Authority** — the single canonical calculation site. Every consumer
   (chart, ledger, detail sheet, accessibility text, widget, intent,
   notification, HealthKit write) must consume that one result. Parallel
   reimplementations are forbidden.
2. **Confidence tier** — how the metric reports its evidence quality
   (e.g. learning → unverified → personal baseline → validated). A metric with
   only one implicit "always trustworthy" tier is not acceptable unless it is a
   direct physical measurement.
3. **Provenance** — where the underlying samples came from (live strap stream,
   historical offload, user entry, derived), carried with the stored value so
   later surfaces can disclose it.
4. **Freeze semantics** — whether the value is frozen at settlement (and if so,
   the receipt schema) or recomputed live. Frozen historical values must never
   be recomputed with later baselines or profile edits.
5. **Fail-closed behavior** — what the surface shows when inputs are missing.
   The answer must be a gap, a label, or absence; never a population average or
   a default percent.

## Existing authorities (do not reinvent)

| Concept | Authority |
| --- | --- |
| Recovery | `Metrics.recoveryV2` → `AtriaAnalytics.Recovery.estimate(hrvSnapshot:...)`; frozen scores replay via `FrozenRecoverySummary` |
| Strain kernel | `AtriaStrainLoadModel` (Banister TRIMP, HRR form) |
| Strain exactness | `Metrics.StrainPresentation.resolve` |
| Sleep Need | `AtriaSleepBudget.sleepNeedComponents`; historical nights read their `FrozenNeed` receipt |
| Sleep Consistency | `AtriaSleepConsistency.result` |
| HR zones | HRR boundaries frozen per workout (`AtriaHRRZoneBoundaries`) |
| Cycle vs civil day | `AtriaHealthMetricAuthority` |
| SpO2 / skin temp | Research-only; gated by `AtriaResearchProbe` validated-decoder flags per docs/14 |

## Schema additions under this policy

- `DailyRollupStoreEntry.sleepScore` (2026-08-14, GAP-06): the night's
  provisional composite Sleep Score receipt. Additive/optional — legacy rows
  decode nil via `decodeIfPresent`; cold-session imports omit it, and a re-mint
  from the same frozen inputs (frozen need, morning-frozen consistency,
  motion-qualified efficiency) reproduces it deterministically, so no
  migration pass is required.

## Forbidden

- Estimating or displaying HRV from heart-rate-only data.
- Showing SpO2 or absolute skin temperature as measured values before the
  docs/14 validation protocol passes (generation/firmware-locked).
- Recomputing historical frozen Sleep Need, Recovery, or zone boundaries with
  later profile data.
- Population averages as substitutes for personal baselines.
- Presenting partial evidence as exact whole-day totals without labeling.
