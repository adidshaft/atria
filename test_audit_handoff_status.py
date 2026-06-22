#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path

from tools import audit_handoff_status


def touch(root: Path, rel: Path) -> None:
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("", encoding="utf-8")


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
        self.assertIn("accessibility_performance_proof", report["blockers"])
        self.assertIn("external_reference_validation", report["blockers"])
        self.assertEqual(report["external_reference_status"], "required")

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
