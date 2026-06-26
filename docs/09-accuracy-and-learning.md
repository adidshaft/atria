# Accuracy, Feedback & Continuous Learning

Three reinforcing pillars added to make the data trustworthy and the app
genuinely useful over time.

## Accuracy (clean signal in)

In `AtriaBLEManager.record(_:)`:

- **Skin-contact detection** — a `0` BPM means the optical sensor lost contact;
  it's flagged (`hasContact = false`, "no skin contact" shown) and **excluded**
  from the series rather than logged as a real 0.
- **HRV contact gate** — RR intervals do not feed the clinical HRV window until
  live HR contact has been stable for at least 10 seconds. Contact loss resets
  the HRV window, logs `hrv_quality`, and keeps HRV in **learning**.
- **RR artifact transparency** — rejected RR intervals stay in the capture CSV
  and appear as orange points on the tachogram, while corrected intervals draw
  the line used for HRV metrics.
- **Motion-artifact rejection** — an isolated reading >50 bpm off the recent
  median (common during jumping) is treated as noise: logged as `hr_artifact` in
  captures but kept **out of session stats/chart**.
- **Display smoothing** — the big number shows a 5-sample median to reduce
  flicker, while the **raw** sample is stored in the session so stats stay
  faithful to the sensor.

## Feedback (insight out)

- **Baseline card** (main screen) — your learned resting HR, and how the current
  session's resting compares (`↓ 3 bpm below your norm` / `↑ above your norm`).
- **Time in zone** (session detail) — seconds spent in each HR zone as a bar
  breakdown, so a run is summarized at a glance.
- **Resting-HR trend** (History screen) — each session's stable resting HR
  plotted over time with the learned baseline as a dashed reference line, so the
  adaptation is *visible*: you can watch your resting HR drift down as fitness
  improves and the baseline track it.

## Continuous learning (adapts to you)

`PersonalBaseline` (in `Insights.swift`, persisted in UserDefaults):

- After **every saved session**, the session's **stable resting HR** (10th
  percentile, robust to single dips) is folded into an **exponential moving
  average** (α = 0.25). "Your normal" is learned, not guessed.
- Surfaced via the baseline card; drives the recovery-style feedback above.
- Trained from `SessionStore.add(_:)`, so both manual and auto-saved sessions
  teach it.

## Why this matters

Garbage-in artifacts would corrupt resting/peak and poison the baseline. By
cleaning the signal first, then learning from clean sessions, the feedback gets
**more accurate the more you wear it** — without any WHOOP cloud.
