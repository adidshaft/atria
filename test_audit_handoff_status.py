#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools import audit_handoff_status


def touch(root: Path, rel: Path) -> None:
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("", encoding="utf-8")


def write_passing_long_wear_summary(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "preset": "overnight",
        "planned_samples": 11,
        "planned_duration_s": 36_000,
        "acceptance_status": "pass",
        "acceptance_blockers": [],
        "criteria": {
            "preset": "overnight",
            "min_samples": 9,
            "min_span_s": 28_800,
            "min_coverage_percent": 85.0,
            "max_gap_s": 30.0,
            "allowed_thermal": ["nominal", "fair"],
            "max_battery_drop_percent": 35.0,
        },
        "thermal_states": ["nominal", "fair"],
        "battery_delta": -12,
        "latest_recent_session_span_s": 30_000.0,
        "latest_recent_session_coverage_percent": 91.0,
    }), encoding="utf-8")


def write_passing_accessibility_performance(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "device": "iPhone 15 Pro",
        "accessibility_checks": {
            "reduce_transparency": True,
            "increase_contrast": True,
            "reduce_motion": True,
            "light_mode": True,
            "dark_mode": True,
        },
        "dashboard_scroll_fps": 60.0,
        "instruments_trace": "docs/evidence/accessibility-performance/trace.trace",
        "measured_at": "2026-06-22T12:00:00Z",
        "app_commit": current_test_commit(path),
        "app_build": "Atria 1.0 (100)",
        "notes": "Measured on physical iPhone.",
    }), encoding="utf-8")


def current_test_commit(path: Path) -> str:
    for parent in [path.parent, *path.parents]:
        git_dir = parent / ".git"
        if git_dir.exists():
            result = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=parent,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            )
            return result.stdout.strip()
    return "abcdef1234567890"


class AuditHandoffStatusTests(unittest.TestCase):
    def test_reports_physical_blockers_from_failed_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            summary.parent.mkdir(parents=True)
            summary.write_text(json.dumps({
                "acceptance_status": "fail",
                "acceptance_blockers": ["session_span", "thermal"],
                "acceptance_diagnostics": {
                    "session_span": {
                        "observed_s": 2731.1,
                        "required_min_s": 28800,
                        "ok": False,
                    },
                    "thermal": {
                        "observed": ["serious"],
                        "allowed": ["nominal", "fair"],
                        "ok": False,
                    },
                },
                "thermal_states": ["serious"],
                "battery_delta": 0,
                "latest_recent_session_span_s": 2731.1,
                "latest_recent_session_coverage_percent": 50.0,
            }), encoding="utf-8")

            report = audit_handoff_status.evaluate(repo, summary)

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["local_status"], "pass")
        self.assertEqual(report["physical_long_wear"]["status"], "fail")
        self.assertIn("session_span", report["blockers"])
        self.assertIn("thermal", report["blockers"])
        self.assertEqual(
            report["physical_long_wear"]["acceptance_diagnostics"]["session_span"]["observed_s"],
            2731.1,
        )
        self.assertEqual(
            report["physical_long_wear"]["acceptance_diagnostics"]["thermal"]["allowed"],
            ["nominal", "fair"],
        )
        self.assertIn("accessibility_performance_proof", report["blockers"])
        self.assertIn("external_reference_validation", report["blockers"])
        self.assertEqual(report["external_reference_status"], "required")

    def test_short_custom_long_wear_pass_cannot_complete_physical_acceptance(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            summary.parent.mkdir(parents=True)
            summary.write_text(json.dumps({
                "preset": "custom",
                "planned_samples": 2,
                "planned_duration_s": 60,
                "acceptance_status": "pass",
                "acceptance_blockers": [],
                "criteria": {
                    "preset": "custom",
                    "min_samples": 1,
                    "min_span_s": 30,
                    "min_coverage_percent": 10.0,
                    "max_gap_s": 999.0,
                    "allowed_thermal": ["nominal", "fair", "serious"],
                    "max_battery_drop_percent": 100.0,
                },
                "thermal_states": ["nominal"],
                "battery_delta": 0,
                "latest_recent_session_span_s": 60.0,
                "latest_recent_session_coverage_percent": 100.0,
            }), encoding="utf-8")

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["physical_long_wear"]["status"], "fail")
        self.assertIn("overnight_preset", report["blockers"])
        self.assertIn("overnight_planned_duration", report["blockers"])
        self.assertIn("overnight_min_span", report["blockers"])

    def test_missing_long_wear_diagnostics_are_synthesized(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            summary.parent.mkdir(parents=True)
            summary.write_text(json.dumps({
                "acceptance_status": "fail",
                "acceptance_blockers": ["session_span", "session_coverage", "thermal"],
                "samples": 1,
                "active_ok_samples": 1,
                "criteria": {
                    "min_samples": 1,
                    "min_span_s": 28800,
                    "min_coverage_percent": 85.0,
                    "max_gap_s": 30.0,
                    "allowed_thermal": ["nominal", "fair"],
                    "max_battery_drop_percent": 35.0,
                },
                "thermal_states": ["serious"],
                "battery_delta": 0,
                "latest_recent_session_span_s": 2731.1,
                "latest_recent_session_coverage_percent": 50.0,
                "max_active_accepted_gap_s": 0.0,
                "max_recent_accepted_gap_s": 0.0,
            }), encoding="utf-8")

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)

        diagnostics = report["physical_long_wear"]["acceptance_diagnostics"]
        self.assertEqual(diagnostics["session_span"]["observed_s"], 2731.1)
        self.assertEqual(diagnostics["session_span"]["required_min_s"], 28800)
        self.assertEqual(diagnostics["session_coverage"]["observed_percent"], 50.0)
        self.assertEqual(diagnostics["thermal"]["observed"], ["serious"])
        self.assertFalse(diagnostics["thermal"]["ok"])

    def test_external_reference_can_be_explicitly_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            summary.parent.mkdir(parents=True)
            summary.write_text(json.dumps({
                "acceptance_status": "fail",
                "acceptance_blockers": ["session_span"],
                "thermal_states": ["nominal"],
                "battery_delta": 0,
                "latest_recent_session_span_s": 3600.0,
                "latest_recent_session_coverage_percent": 70.0,
            }), encoding="utf-8")

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["external_reference_status"], "skipped")
        self.assertIn("session_span", report["blockers"])
        self.assertIn("accessibility_performance_proof", report["blockers"])
        self.assertNotIn("external_reference_validation", report["blockers"])

    def test_accessibility_performance_evidence_is_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["physical_long_wear"]["status"], "pass")
        self.assertEqual(report["accessibility_performance"]["status"], "missing")
        self.assertIn("accessibility_performance_proof", report["blockers"])
        self.assertIn("missing_accessibility_performance_summary", report["blockers"])

    def test_accessibility_performance_evidence_must_cover_required_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            accessibility.parent.mkdir(parents=True)
            accessibility.write_text(json.dumps({
                "device": "iPhone 14",
                "accessibility_checks": {"reduce_motion": True},
                "dashboard_scroll_fps": 52.0,
                "instruments_trace": "",
                "measured_at": "",
                "app_commit": "",
                "app_build": "",
            }), encoding="utf-8")

            report = audit_handoff_status.evaluate(
                repo,
                summary,
                skip_external_reference=True,
                accessibility_performance_path=accessibility,
            )

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["accessibility_performance"]["status"], "fail")
        self.assertIn("accessibility_performance_device", report["blockers"])
        self.assertIn("accessibility_reduce_transparency", report["blockers"])
        self.assertIn("dashboard_scroll_fps", report["blockers"])
        self.assertIn("missing_instruments_trace", report["blockers"])
        self.assertIn("missing_measured_at", report["blockers"])
        self.assertIn("missing_app_commit", report["blockers"])
        self.assertIn("missing_app_build", report["blockers"])

    def test_accessibility_performance_evidence_can_complete_non_reference_audit(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)

            report = audit_handoff_status.evaluate(
                repo,
                summary,
                skip_external_reference=True,
                accessibility_performance_path=accessibility,
            )

        self.assertEqual(report["status"], "complete")
        self.assertEqual(report["accessibility_performance"]["status"], "pass")
        self.assertEqual(report["blockers"], [])

    def test_accessibility_performance_app_commit_must_match_repo_head(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            touch(repo, Path("tracked.txt"))
            subprocess.run(["git", "add", "tracked.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "initial"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)
            data = json.loads(accessibility.read_text(encoding="utf-8"))
            data["app_commit"] = "0" * 40
            accessibility.write_text(json.dumps(data), encoding="utf-8")

            report = audit_handoff_status.evaluate(
                repo,
                summary,
                skip_external_reference=True,
                accessibility_performance_path=accessibility,
            )

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["accessibility_performance"]["status"], "fail")
        self.assertIn("app_commit_mismatch", report["blockers"])

    def test_default_accessibility_performance_summary_is_discovered(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / audit_handoff_status.DEFAULT_ACCESSIBILITY_PERFORMANCE_SUMMARY
            write_passing_accessibility_performance(accessibility)

            report = audit_handoff_status.evaluate(
                repo,
                summary,
                skip_external_reference=True,
            )

        self.assertEqual(report["status"], "complete")
        self.assertEqual(report["accessibility_performance"]["summary"], str(accessibility))

    def test_accessibility_performance_template_is_not_treated_as_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            template = repo / "docs/evidence/accessibility-performance/summary.template.json"
            write_passing_accessibility_performance(template)

            report = audit_handoff_status.evaluate(
                repo,
                summary,
                skip_external_reference=True,
            )

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["accessibility_performance"]["status"], "missing")
        self.assertIn("missing_accessibility_performance_summary", report["blockers"])

    def test_missing_summary_is_not_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)

            report = audit_handoff_status.evaluate(repo)

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["physical_long_wear"]["status"], "missing")
        self.assertIn("missing_overnight_summary", report["blockers"])


if __name__ == "__main__":
    unittest.main()
