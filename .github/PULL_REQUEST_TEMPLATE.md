## What this changes

<!-- One or two sentences. What behaviour is different after this merges? -->

## Why

<!-- The defect, gap, or requirement. Link the issue: Fixes #NN -->

## Evidence

<!--
Atria's bar is evidence, not intent. Fill in what applies and delete the rest.
-->

- **Tests:** <!-- suite + pass count, e.g. "AtriaTests focused sleep matrix 91/91" -->
- **Physical device:** <!-- what was observed on a real iPhone + strap, or "not required because…" -->
- **Fixture:** <!-- the regression that would have caught this -->

## Honesty checklist

- [ ] No metric shows a number the evidence does not support — blockers stay truthful and named
- [ ] Gaps in data render as gaps; nothing is interpolated or carried forward
- [ ] No new value is written to HealthKit without reference validation
- [ ] Anything unproven is labelled as an estimate, not a measurement
- [ ] Data stays on device

## Risk

<!-- What could this break? BLE transport, background lifecycle, and the archive
     are the three areas where mistakes are expensive. -->
