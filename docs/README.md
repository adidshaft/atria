# Atria documentation

Everything here is written against real device evidence. Where a document makes a
claim it cannot prove, it says so.

---

## Start here

| Document | What it is for |
|---|---|
| [**SETUP.md**](SETUP.md) | Fresh Mac and iPhone: build, sign, run on device, common errors, and which logs are safe to share. |
| [**WHOOP4_PROTOCOL_FINDINGS.md**](WHOOP4_PROTOCOL_FINDINGS.md) | The protocol reference. What is decoded, what is not, and the evidence behind each field. |
| [**16-metric-authority-and-confidence-policy.md**](16-metric-authority-and-confidence-policy.md) | The rule that governs the whole app: when a number may be shown, and what to show instead. |

## Protocol and hardware

| Document | |
|---|---|
| [02-device-ble-map.md](02-device-ble-map.md) | Services, characteristics, and the device map |
| [04-macos-ble-setup.md](04-macos-ble-setup.md) | macOS-side BLE exploration tooling |
| [13-sniffer-capture.md](13-sniffer-capture.md) | Capturing and reading a sniffer trace |
| [drain-keeping-flush-design.md](drain-keeping-flush-design.md) | Historical drain, ACK cursor, and flush policy |

## Sensor validation

| Document | Verdict |
|---|---|
| [**DECODER_VALIDATION_2026-08-20_V24.md**](DECODER_VALIDATION_2026-08-20_V24.md) | The V24 layout validated against 37,086 real records. Skin temperature `[68:70]` is a **real** thermal signal; the SpO₂ candidate fields are **DC-only** and yield a constant ~80 % artifact. |
| [14-spo2-skin-temperature-decoder-validation.md](14-spo2-skin-temperature-decoder-validation.md) | The validation plan these decoders are held to |
| [15-health-monitor-biomarker-study.md](15-health-monitor-biomarker-study.md) | Biomarker study notes |
| [research-validation-corpus.md](research-validation-corpus.md) | Rules and fixtures for reproducible sensor validation |

## Metrics and modelling

| Document | |
|---|---|
| [17-muscular-load-and-fusion.md](17-muscular-load-and-fusion.md) | Muscular load and how it fuses into strain |
| [SLEEP_STAGE_DESIGN_2026-08-20.md](SLEEP_STAGE_DESIGN_2026-08-20.md) | RR-refined sleep staging |
| [STRENGTHEN_FIVE_PLAN_2026-08-20.md](STRENGTHEN_FIVE_PLAN_2026-08-20.md) | Recovery, strain, stress, steps, widgets |
| [RESEARCH_BRIEF_2026-08-20_ACCURACY.md](RESEARCH_BRIEF_2026-08-20_ACCURACY.md) | Accuracy research brief |
| [export-schema.md](export-schema.md) | The local export format |

## Product and planning

| Document | |
|---|---|
| [WHOOP_REMAINING_PRODUCT_GAPS.md](WHOOP_REMAINING_PRODUCT_GAPS.md) | The original full gap plan — mostly landed |
| [WHOOP_REPLACEMENT_ASSESSMENT.md](WHOOP_REPLACEMENT_ASSESSMENT.md) | What Atria does and does not replace |
| [GOAL_strap_steps_drain.md](GOAL_strap_steps_drain.md) | The standing steps-drain goal, constraints, and proven root cause — see [#21](https://github.com/adidshaft/atria/issues/21) |
| [UI_DECLUTTER_PLAN_2026-08-20.md](UI_DECLUTTER_PLAN_2026-08-20.md) | UI reduction passes |
| [CLAUDE_FINAL_ACCEPTANCE_CHECKLIST.md](CLAUDE_FINAL_ACCEPTANCE_CHECKLIST.md) | Release acceptance checklist |

## Session handoffs — historical

`CLAUDE_HANDOFF_6` … `CLAUDE_HANDOFF_13` and everything under
[`handoff/`](handoff/) are point-in-time working records. They are kept because
issue threads and commit messages cite them by path, and because they document
*why* decisions were made — but they are **snapshots, not current truth**. When a
handoff and the code disagree, the code is right.

The most recent are
[13 (motion + shifted sleep)](CLAUDE_HANDOFF_13_MOTION_AND_SHIFTED_SLEEP_CLOSURE.md)
and
[12 (sleep, stress continuity, UI dedup)](CLAUDE_HANDOFF_12_CURRENT_SLEEP_STRESS_CONTINUITY_AND_UI_DEDUP.md).

---

## The one rule

> A metric is shown only when the evidence supports it. When it does not, the
> surface names the exact blocker instead. No estimate is ever presented as a
> measurement, no gap is ever interpolated, and no card is filled to look complete.

If a change here would break that, it does not ship.
