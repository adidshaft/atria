<!-- Repository workflow: all work lands on dev; integration PRs promote dev to main. -->

## What this changes

<!-- One or two sentences. What behaviour is different after this merges? -->

## Why

<!-- The defect, gap, or requirement. Link the issue: Fixes #NN -->

## Evidence

<!--
Atria's bar is evidence, not intent. Fill in what applies and delete the rest.
-->

- **Base and tested commit:** <!-- base branch + tested commit SHA -->
- **Tests/build:** <!-- exact commands and pass/fail/skip counts; disclose checks not run -->
- **Known failures:** <!-- compare with the base; link tracking issues (e.g. #44) rather than claiming a green suite -->
- **Physical device:** <!-- what was observed on a real iPhone + strap, or "not required because…" -->
- **Fixture:** <!-- reproducible public/synthetic regression; disclose tests skipped without private fixtures -->
- **Evidence scope:** <!-- distinguish Mac experiments, simulator logic checks, and production iPhone behavior -->

## Honesty checklist

- [ ] No metric shows a number the evidence does not support — blockers stay truthful and named
- [ ] Gaps in data render as gaps; nothing is interpolated or carried forward
- [ ] No new value is written to HealthKit without reference validation
- [ ] Anything unproven is labelled as an estimate, not a measurement
- [ ] Data stays on device unless the user explicitly chooses a documented sharing/export flow
- [ ] Shared evidence and staged fixtures contain no unintended health data, device identifiers, or private paths
- [ ] Linked issues reflect remaining integration and acceptance work; prototype results are not treated as shipped behavior

## Risk

<!-- What could this break? BLE transport, background lifecycle, and the archive
     are the three areas where mistakes are expensive. -->
