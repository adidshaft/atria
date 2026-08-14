# 17 — Muscular Load & Fusion with Cardiovascular Strain

Status: **shipped, provisional calibration** (WP-8 / GAP-09 of the
full-replacement directive, 2026-08-14). Deterministic and transparent; the
constants are engineering-provisional and await calibration against the local
research export (AtriaResearchBundle v6 receipts). This is an independent
model — no WHOOP formula was copied or reverse-fitted.

## Muscular input (per logged strength session)

Authority: `AtriaStrengthLog.muscularLoadReceipt(for:)`.

- A set is **load-qualified** when it has a positive rep count and a frozen
  effective load (`effectiveLoadKg`, e.g. body-mass estimate for pull-ups) or a
  user-entered external weight.
- The **muscular input score** (0–100) exists only when every load-qualified
  set carries an explicit RPE — a missing RPE is never converted into an
  average effort:

  ```text
  effortAdjustedVolume = Σ effectiveLoad × reps × (0.55 + 0.45 × RPE/10)
  density  = min(0.15, 0.03 × quickSupersetTransitions)   // ≤ 90 s handoffs
  score    = min(100, 100 × (1 − exp(−effortAdjustedVolume × (1 + density) / 5000)))
  ```

- Superset density comes from the WP-7 receipts (`supersetGroupID`, order,
  observed transition seconds). Editing a set preserves its receipt; regrouping
  reuses the group id (`AtriaStrengthLog.supersetReceipt` is the only
  derivation site).

## Fusion (per day)

Authority: `AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore:)` +
`SessionStore.muscularTRIMPEquivalentTotal(_:)`.

```text
equivalent(session) = 45 × (score / 100)^1.6      // 0 when score is nil
dayLoad             = cardioTRIMP + Σ equivalents(day's confirmed workouts)
dayStrain           = displayScore(dayLoad)        // existing monotonic, saturating 0–21 map
```

- **45** is the TRIMP-equivalent ceiling for a maximal logged session — below
  the kernel's own observed reference of TRIMP ≈ 65 for a hard strength hour's
  *cardio* component, because the muscular term only represents load the HR
  integral does not already count.
- **^1.6** (power law > 1): light accessory work adds little; genuinely heavy
  logged sessions add real load. Chosen for explainability, not fitted.
- Fusion happens in TRIMP space *before* the one saturating 0–21 display map,
  so there is exactly one Strain number and no parallel scale.

### Wired surfaces (all four fuse identically)

1. Today's hero aggregate — `SessionStore.homeSavedAggregate` (cache
   invalidated on every workout mutation).
2. Widget day TRIMP — `SessionStore.todayTRIMP`.
3. Frozen daily rollups — the rebuild path adds
   `muscularTRIMPEquivalentTotal(confirmedWorkoutsByDay[day])`.
4. Overview trend points — `SessionStore.makeOverviewTrendPoints`.

Not wired (documented): the thin-day wear-strain fallback (a day with a logged
strength workout always takes the computed path), and `perDayStrains`
(test-only consumer). A trend day whose only evidence is a logged workout with
zero HR sessions keeps no trend point (trend rows require session identity).

## Guarantees (tested in AtriaMuscularFusionTests, AtriaStrengthProgressPresentationTests)

- Identical saved sets → identical receipts and identical fused strain.
- Strictly monotone in weight, reps, RPE, and added qualified sets.
- Cardio-only days are bit-identical to the pre-fusion result.
- An unlogged "Strength" session, or one with incomplete RPE coverage,
  contributes exactly zero muscular load — never inferred from HR or duration.
- Bounded: equivalent ≤ 45 per session; the 0–21 display map bounds the day.

## Forbidden (unchanged)

- Inferring muscular load from HR or duration alone.
- Assigning load to unlogged sessions.
- Presenting the fused number as validated or WHOOP-equivalent.
