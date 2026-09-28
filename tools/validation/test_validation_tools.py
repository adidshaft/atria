#!/usr/bin/env python3
"""Offline checks for tools/validation (synthetic data only, no device)."""
import csv
import json
import math
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import score  # noqa: E402

try:
    import ref_hr_strap  # needs PyObjC; skip parser test without it
except Exception:  # pragma: no cover
    ref_hr_strap = None


def write(path, header, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


class ScoreTests(unittest.TestCase):
    def test_hr_detects_bias_and_lag(self):
        t0 = 1_800_000_000
        ref = [(t0 + s, 60 + 20 * math.sin(s / 20)) for s in range(300)]
        atria = [(t + 3, v + 1) for t, v in ref]  # 3 s late, +1 bpm
        w = score.hr_window(atria, ref, t0, t0 + 300)
        self.assertEqual(w["lag_s"], 3)
        self.assertAlmostEqual(w["bias"], 1, delta=1.5)

    def test_rr_match_and_rmssd(self):
        t, rows = 1_800_000_000.0, []
        for i in range(200):
            v = 800 + (40 if i % 2 else -40)
            t += v / 1000
            rows.append((t, v))
        w = score.rr_window(rows, rows, rows[0][0], rows[-1][0] + 1)
        self.assertEqual(w["match"], 1.0)
        self.assertEqual(w["rmssd_bias"], 0.0)
        self.assertAlmostEqual(w["rmssd_ref"], 80, delta=1)

    def test_sleep_errors_in_minutes(self):
        with tempfile.TemporaryDirectory() as d:
            s, di = Path(d) / "s.csv", Path(d) / "d.csv"
            write(s, ["start", "end", "is_nap", "source"], [[1000, 1000 + 8 * 3600, "False", "x"]])
            write(di, ["lights_out", "wake"], [[1000 - 600, 1000 + 8 * 3600 + 300]])
            r = score.sleep_scores(str(s), str(di))[0]
            self.assertEqual((r["onset_err_min"], r["wake_err_min"]), (10.0, -5.0))

    @unittest.skipIf(ref_hr_strap is None, "PyObjC not available")
    def test_heart_rate_measurement_parser(self):
        # flags 0x10 (RR present), 8-bit HR 72, two RR of 1024 and 512 ticks
        bpm, rr = ref_hr_strap.parse_measurement(bytes([0x10, 72, 0x00, 0x04, 0x00, 0x02]))
        self.assertEqual(bpm, 72)
        self.assertEqual(rr, [1000.0, 500.0])


if __name__ == "__main__":
    unittest.main()
