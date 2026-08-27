---
name: Metric validation
about: Track a metric that needs reference-backed proof before it can be trusted
title: "[Validation] "
labels: "type: validation"
assignees: ""
---

## Metric

Which value, on which surface, from which sensor field.

## Current state

What Atria displays today — including the exact blocker copy if it is withheld.

## Why it is not yet trustworthy

Decoder uncertainty, missing baseline, confound, or absent reference.

## Reference method

The independent device or corpus this will be compared against, and the protocol
for collecting paired measurements.

## Done when

- [ ] Field, byte order, scale, units, and sentinel values identified
- [ ] Paired comparison across the stated conditions
- [ ] Acceptance thresholds committed alongside the scoring version
- [ ] Gates preserved: corrupted or missing evidence stays unavailable

## Non-negotiable

A value is never shipped to fill a card. If the evidence does not support a
number, the surface shows a truthful blocker instead.
