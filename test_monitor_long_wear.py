#!/usr/bin/env python3
import argparse
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

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
        "app_commit": None,
    }
    defaults.update(overrides)
    return argparse.Namespace(**defaults)


class MonitorLongWearTests(unittest.TestCase):
    def test_parses_harness_summary_lines(self):
        parsed = monitor_long_wear.parsed_summary(
            "\n".join([
                "noise",
                "ATRIADBG_SESSIONS_SUMMARY status=ok sessions=204 recent_span_s=28800.0 recent_coverage_percent=91.5",
                "ATRIADBG_ACTIVE_JOURNAL_SEGMENTS_SUMMARY status=ok duration_s=120.0 delta_samples=121 battery=66 thermal=fair",
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
        self.assertEqual(result["acceptance_diagnostics"]["session_span"]["observed_s"], 9 * 60 * 60)
        self.assertEqual(result["acceptance_diagnostics"]["session_span"]["required_min_s"], 8 * 60 * 60)
        self.assertTrue(result["acceptance_diagnostics"]["thermal"]["ok"])

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
        self.assertEqual(result["acceptance_diagnostics"]["session_span"]["observed_s"], 2731.1)
        self.assertEqual(result["acceptance_diagnostics"]["session_span"]["required_min_s"], 8 * 60 * 60)
        self.assertEqual(result["acceptance_diagnostics"]["thermal"]["observed"], ["serious"])
        self.assertEqual(result["acceptance_diagnostics"]["thermal"]["allowed"], ["nominal", "fair"])
        self.assertFalse(result["acceptance_diagnostics"]["session_coverage"]["ok"])

    def test_stamp_run_provenance_records_commit_and_utc_timestamps(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            (repo / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "Initial"], cwd=repo, check=True, stdout=subprocess.DEVNULL)
            expected_commit = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            final = {}

            monitor_long_wear.stamp_run_provenance(final, repo, "2026-06-22T00:00:00Z")

            self.assertEqual(final["monitor_started_at"], "2026-06-22T00:00:00Z")
            self.assertEqual(final["app_commit"], expected_commit)
            self.assertEqual(final["monitor_commit"], expected_commit)
            self.assertIsInstance(final["monitor_finished_at"], str)
            self.assertIn("T", final["monitor_finished_at"])
            self.assertTrue(final["monitor_finished_at"].endswith("Z"))

    def test_stamp_run_provenance_can_pin_installed_app_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            (repo / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "Initial"], cwd=repo, check=True, stdout=subprocess.DEVNULL)
            monitor_commit = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            final = {}

            monitor_long_wear.stamp_run_provenance(final, repo, "2026-06-22T00:00:00Z", "installed-app")

        self.assertEqual(final["app_commit"], "installed-app")
        self.assertEqual(final["monitor_commit"], monitor_commit)

    def test_write_run_metadata_records_planned_provenance_before_samples_finish(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            (repo / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "Initial"], cwd=repo, check=True, stdout=subprocess.DEVNULL)
            namespace = args(preset="overnight", label="night", app_commit="installed-app")
            metadata = repo / "run.json"

            monitor_long_wear.write_run_metadata(metadata,
                                                 repo,
                                                 namespace,
                                                 samples_count=11,
                                                 interval_seconds=3600,
                                                 monitor_started_at="2026-06-22T00:00:00Z")
            data = json.loads(metadata.read_text(encoding="utf-8"))

        self.assertEqual(data["label"], "night")
        self.assertEqual(data["preset"], "overnight")
        self.assertEqual(data["planned_samples"], 11)
        self.assertEqual(data["planned_duration_s"], 36000)
        self.assertEqual(data["app_commit"], "installed-app")
        self.assertTrue(data["monitor_commit"])

    def test_detached_launchctl_command_preserves_monitor_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            namespace = args(
                device="DEVICE-1",
                out_dir=Path("logs/live-device/long-wear-monitor"),
                preset="overnight",
                label="overnight handoff/21",
                samples=11,
                interval=3600,
                app_commit="abc123",
                allowed_thermal=["nominal", "fair"],
            )
            log_path = repo / "logs/live-device/long-wear-monitor/overnight handoff-21.out"

            command = monitor_long_wear.detached_command(repo, namespace, log_path)

        self.assertEqual(command[:4], ["launchctl", "submit", "-l", "com.adidshaft.atria.longwear.overnight-handoff-21"])
        shell = command[-1]
        self.assertIn("--preset overnight", shell)
        self.assertIn("--label 'overnight handoff/21'", shell)
        self.assertIn("--device DEVICE-1", shell)
        self.assertIn("--app-commit abc123", shell)
        self.assertIn("--allowed-thermal nominal fair", shell)
        self.assertIn(">>", shell)
        self.assertNotIn("--launchctl-detach", shell)


if __name__ == "__main__":
    unittest.main()
