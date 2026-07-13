# July 11 step-calibration archive coverage

This report is a read-only coverage audit. It does not run a parameter sweep,
fit a gain, or promote step-detector constants.

## Method

`tools/summarize_step_archive_coverage.py` recursively reads calibration CSVs,
deduplicates rows copied between pulls, validates WHOOP framing and both CRCs,
requires the fixed R10 `0x2b/0x0a` layout, and deduplicates nonzero device
timestamps the same way as production.

Coverage is assigned using the decoded device timestamp, not the later iPhone
receipt timestamp. Each accepted R10 frame contains 100 acceleration samples at
100 Hz. Device-timestamp delta other than one second starts a new segment;
samples from separate segments must not be concatenated for step counting.

The most complete pulled directory examined is now:

`evidence/pre-atomic-density-install-20260712-0611/atria-step-calibration`

It contains 11,622 unique CSV rows. All 11,622 decode as CRC-valid R10 rows.
After deduplicating repeated device timestamps, 11,201 unique frames / 1,120,100
acceleration samples remain across all retained dates. The larger archive still
contains zero frames in every supplied walk window. The window results below use
only July 11 device timestamps.

## Supplied walk windows

| Supplied label | IST window | Explicit count in note | Unique frames | Samples | Coverage | Calibration use |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Slow walk | 15:20–15:21 | Not explicit | 0 | 0 | 0% | No |
| Normal walk | 15:24–15:35 | Not explicit | 0 | 0 | 0% | No |
| Brisk walk | 15:29–15:30 | 100 | 0 | 0 | 0% | No |
| Normal walk | 15:35–15:37 | 200 | 0 | 0 | 0% | No |

The last decoded frame before these walks has device time 13:14:44 IST. The
next decoded frame has device time 16:13:09 IST. Therefore no archived R10
sample can be assigned to any part of 15:20–15:37.

The 15:24–15:35 normal label also contains the entire 15:29–15:30 brisk label.
Without independent second-level transition markers, separate normal and brisk
step counts cannot be attributed even if frames are recovered later.

Minute-level boundaries are insufficient for fitting a short counted walk: a
one-minute boundary uncertainty is comparable to the complete 100-step brisk
window. The slow and long normal notes also do not state counted steps directly;
assuming that both mean 100 would import context rather than use supplied
evidence.

## User-selected recovery window

The 16:47–17:37 IST strength/recovery window is a user-selected application
window, not independently proven gym ground truth. It contains:

- 6 unique CRC-valid R10 frames / 600 samples / 6 sample-seconds;
- 0.2% sample payload coverage of the 3,000-second window;
- 6 separate device-timestamp segments (longest segment: one frame);
- a largest uncovered device-time gap of 1,037 seconds.

This window is useful only as evidence of sparse capture. It has neither a
manually counted step total nor continuous motion data and cannot calibrate a
step detector.

## Later unlabeled captures

There are substantial later frames between approximately 18:43 and 18:50 IST.
For example, device time 18:45–18:47 has 120 continuous frames / 12,000 samples
and full two-minute payload coverage. No independently supplied exact walk
start/end markers or counted-step total identify that stream. It must remain
unlabeled and cannot be substituted for one of the 15:20–15:37 walks.

## Conclusion

None of the supplied July 11 walk or recovery windows can be used to fit or
validate step constants without assumptions. The decisive blocker for the four
walks is absence of archived samples, not detector performance. A usable future
calibration needs a charger-free walk with an explicit count, start and end to
the second, and one continuous device-timestamp segment spanning the window.

The replay and fitting tools now select frames by decoded strap device time
rather than delayed iPhone receipt time. They also retain one continuous
streaming-detector state instead of resetting it at artificial one-minute
boundaries. These corrections prevent delayed history and boundary phase from
creating a false calibration result. No production parameter was promoted from
the missing July 11 evidence.
