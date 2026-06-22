#!/usr/bin/env python3
import argparse
import unittest

from tools import monitor_long_wear


def args(**overrides):
    defaults = {
        "preset": "custom",
        "allowed_thermal": ["nominal", "fair"],
        "max_battery_drop": 35.0,
        "min_samples": 2,
        "min_span": 8 * 60 * 60,
        "min_coverage": 85.0,
        "max_gap": 30.0,
    }
    defaults.update(overrides)
    return argparse.Namespace(**defaults)


class MonitorLongWearTests(unittest.TestCase):
    def test_parses_harness_summary_lines(self):
        parsed = monitor_long_wear.parsed_summary(
            "\n".join([
                "noise",
                "WHOOPDBG_SESSIONS_SUMMARY status=ok sessions=204 recent_span_s=28800.0 recent_coverage_percent=91.5",
                "WHOOPDBG_ACTIVE_JOURNAL_SEGMENTS_SUMMARY status=ok duration_s=120.0 delta_samples=121 battery=66 thermal=fair",
            ])
        )

        self.assertEqual(parsed["sessions"]["sessions"], 204)
        self.assertEqual(parsed["sessions"]["recent_span_s"], 28800.0)
        self.assertEqual(parsed["active_journal"]["battery"], 66)
        self.assertEqual(parsed["active_journal"]["thermal"], "fair")

    def test_rollup_uses_latest_ok_samples_and_battery_delta(self):
        final = monitor_long_wear.rollup([
            {
                "active_journal": {
                    "status": "ok",
                    "duration_s": 60.0,
                    "delta_samples": 60,
                    "delta_rr": 55,
                    "max_raw_gap_s": 0.0,
                    "max_accepted_gap_s": 0.0,
                    "thermal": "nominal",
                    "power_mode": "nominal",
                    "battery": 80,
                },
                "sessions": {
                    "status": "ok",
                    "recent_span_s": 28800.0,
                    "recent_coverage_percent": 90.0,
                    "recent_samples": 1000,
                    "recent_rr": 900,
                    "recent_max_raw_gap_s": 0.0,
                    "recent_max_accepted_gap_s": 0.0,
                },
            },
            {
                "active_journal": {
                    "status": "ok",
                    "duration_s": 120.0,
                    "delta_samples": 120,
                    "delta_rr": 110,
                    "max_raw_gap_s": 1.0,
                    "max_accepted_gap_s": 1.0,
                    "thermal": "fair",
                    "power_mode": "fair",
                    "battery": 76,
                },
                "sessions": {
                    "status": "ok",
                    "recent_span_s": 30000.0,
                    "recent_coverage_percent": 92.0,
                    "recent_samples": 1100,
                    "recent_rr": 1000,
                    "recent_max_raw_gap_s": 2.0,
                    "recent_max_accepted_gap_s": 2.0,
                },
            },
        ])

        self.assertEqual(final["latest_active_duration_s"], 120.0)
        self.assertEqual(final["latest_recent_session_span_s"], 30000.0)
        self.assertEqual(final["battery_delta"], -4)
        self.assertEqual(final["thermal_states"], ["fair", "nominal"])

    def test_acceptance_passes_with_overnight_quality_evidence(self):
        final = {
            "samples": 9,
            "active_ok_samples": 9,
            "latest_recent_session_span_s": 9 * 60 * 60,
            "latest_recent_session_coverage_percent": 91.0,
            "max_active_accepted_gap_s": 0.0,
            "max_recent_accepted_gap_s": 2.0,
            "thermal_states": ["fair", "nominal"],
            "battery_delta": -12,
        }

        result = monitor_long_wear.evaluate_acceptance(final, args(preset="overnight"))

        self.assertEqual(result["acceptance_status"], "pass")
        self.assertEqual(result["acceptance_blockers"], [])

    def test_acceptance_fails_for_known_current_blockers(self):
        final = {
            "samples": 1,
            "active_ok_samples": 1,
            "latest_recent_session_span_s": 2731.1,
            "latest_recent_session_coverage_percent": 50.0,
            "max_active_accepted_gap_s": 0.0,
            "max_recent_accepted_gap_s": 0.0,
            "thermal_states": ["serious"],
            "battery_delta": 0,
        }

        result = monitor_long_wear.evaluate_acceptance(final, args(min_samples=1))

        self.assertEqual(result["acceptance_status"], "fail")
        self.assertEqual(result["acceptance_blockers"], ["session_span", "session_coverage", "thermal"])


if __name__ == "__main__":
    unittest.main()
