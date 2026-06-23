#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools import audit_realtime_ble_validation as audit


def write_summary(root: Path, label: str, payload: dict) -> Path:
    path = root / label / "summary.json"
    path.parent.mkdir(parents=True)
    payload = {"label": label, **payload}
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def passing_stream(**extra):
    data = {
        "status": "pass",
        "samples": 91,
        "started_at": "2026-06-23T00:00:00Z",
        "finished_at": "2026-06-23T03:00:00Z",
        "min_raw_notification_delta": 60,
        "min_accepted_sample_delta": 60,
        "max_disconnect_delta": 0,
        "max_hr_continuity_delta": 0,
        "flags": [],
    }
    data.update(extra)
    return data


def passing_state():
    return {
        "status": "ok",
        "fields": {
            "active_journal_freshness": "fresh",
            "active_journal_continuity_status": "active",
            "active_journal_duration_s": "10800",
            "active_journal_samples": "10000",
            "file_durability_status": "saved_sessions_present",
        },
    }


def passing_app_switch(**extra):
    data = passing_stream(
        samples=4,
        started_at="2026-06-23T00:00:00Z",
        finished_at="2026-06-23T00:01:00Z",
        planned_interval_s=20,
        git_commit=audit.MIN_APP_SWITCH_LIFECYCLE_COMMIT,
    )
    data.update(extra)
    return data


class AuditRealtimeBLEValidationTests(unittest.TestCase):
    def test_documented_commands_match_audit_next_actions(self):
        doc = " ".join(
            Path("docs/15-codex-realtime-ble-validation.md")
            .read_text(encoding="utf-8")
            .replace("\\\n", " ")
            .split()
        )

        for action in audit.NEXT_ACTIONS.values():
            self.assertIn(action["command"], doc)

    def test_incomplete_when_required_physical_evidence_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-clock-switch-ok", passing_app_switch())

            report = audit.evaluate(root)

            self.assertEqual(report["status"], "incomplete")
            self.assertIn("daytime_worn_monitor:missing_evidence", report["blockers"])
            self.assertIn("brief_contact_loss:missing_evidence", report["blockers"])
            self.assertIn("sustained_silence_reseat:missing_evidence", report["blockers"])
            self.assertEqual(report["requirements"]["app_switch"]["status"], "pass")
            self.assertIn("T", report["generated_at"])
            self.assertEqual(report["summary_count"], 1)
            self.assertEqual(report["valid_summary_count"], 1)
            self.assertIn("rt-daytime-", report["requirements"]["daytime_worn_monitor"]["next_command"])
            self.assertIn("loosen/lift", report["requirements"]["brief_contact_loss"]["operator_action"])
            self.assertIn("take the strap off", report["requirements"]["sustained_silence_reseat"]["operator_action"])

    def test_full_report_passes_with_all_required_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-daytime-pass", passing_stream(state_pull=passing_state()))
            write_summary(root, "rt-brief-contact-loss-pass", passing_stream(
                samples=5,
                state_pull=passing_state(),
                events={"1": ["brief_contact_loss_start"], "2": ["brief_contact_loss_reseat"]},
                event_outcomes=[{
                    "events": ["brief_contact_loss_reseat"],
                    "status": "recovered",
                    "next_raw_notification_delta": 70,
                    "next_disconnect_delta": 0,
                    "next_hr_continuity_delta": 0,
                }],
            ))
            write_summary(root, "rt-sustained-silence-pass", passing_stream(
                samples=7,
                state_pull=passing_state(),
                events={"1": ["sustained_silence_start"], "3": ["sustained_silence_reseat"]},
                event_outcomes=[{
                    "events": ["sustained_silence_reseat"],
                    "status": "recovered",
                    "next_raw_notification_delta": 80,
                    "next_disconnect_delta": 1,
                    "next_hr_continuity_delta": 1,
                }],
            ))
            write_summary(root, "rt-clock-switch-pass", passing_app_switch())

            report = audit.evaluate(root)

            self.assertEqual(report["status"], "pass")
            self.assertEqual(report["blockers"], [])

    def test_markdown_prints_next_actions_only_for_incomplete_requirements(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-clock-switch-ok", passing_app_switch())

            report = audit.evaluate(root)
            markdown = audit.markdown_summary(report)

            self.assertIn("Next command: `ATRIA_DEVICE_ID=", markdown)
            self.assertIn("Operator action: Wear the strap continuously", markdown)
            self.assertIn("Generated at:", markdown)
            self.assertIn("Summaries inspected:", markdown)
            self.assertIn("Valid summaries:", markdown)
            self.assertIn("Invalid summaries:", markdown)
            self.assertIn("Evidence: samples=`4`, duration_s=`60`, min_raw_delta=`60`", markdown)
            self.assertIn("min_accepted_delta=`60`", markdown)
            app_switch_section = markdown.split("- `app_switch`: `pass`", 1)[1]
            self.assertNotIn("Next command:", app_switch_section)

    def test_invalid_summary_is_reported_without_crashing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-clock-switch-ok", passing_app_switch())
            bad = root / "rt-daytime-partial" / "summary.json"
            bad.parent.mkdir()
            bad.write_text("{", encoding="utf-8")

            report = audit.evaluate(root)
            markdown = audit.markdown_summary(report)

            self.assertEqual(report["summary_count"], 2)
            self.assertEqual(report["valid_summary_count"], 1)
            self.assertEqual(len(report["invalid_summaries"]), 1)
            self.assertIn("rt-daytime-partial/summary.json", report["invalid_summaries"][0]["summary"])
            self.assertIn("invalid_summary:", " ".join(report["blockers"]))
            self.assertIn("## Invalid Summaries", markdown)
            self.assertIn("JSONDecodeError", markdown)

    def test_invalid_summary_blocks_otherwise_passing_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-daytime-pass", passing_stream(state_pull=passing_state()))
            write_summary(root, "rt-brief-contact-loss-pass", passing_stream(
                samples=5,
                state_pull=passing_state(),
                events={"1": ["brief_contact_loss_start"], "2": ["brief_contact_loss_reseat"]},
                event_outcomes=[{
                    "events": ["brief_contact_loss_reseat"],
                    "status": "recovered",
                    "next_raw_notification_delta": 70,
                    "next_disconnect_delta": 0,
                    "next_hr_continuity_delta": 0,
                }],
            ))
            write_summary(root, "rt-sustained-silence-pass", passing_stream(
                samples=7,
                state_pull=passing_state(),
                events={"1": ["sustained_silence_start"], "3": ["sustained_silence_reseat"]},
                event_outcomes=[{
                    "events": ["sustained_silence_reseat"],
                    "status": "recovered",
                    "next_raw_notification_delta": 80,
                    "next_disconnect_delta": 1,
                    "next_hr_continuity_delta": 1,
                }],
            ))
            write_summary(root, "rt-clock-switch-pass", passing_app_switch())
            bad = root / "rt-daytime-corrupt" / "summary.json"
            bad.parent.mkdir()
            bad.write_text("{", encoding="utf-8")

            report = audit.evaluate(root)

            self.assertEqual(report["status"], "incomplete")
            self.assertEqual(report["valid_summary_count"], 4)
            self.assertTrue(any(blocker.startswith("invalid_summary:") for blocker in report["blockers"]))
            self.assertIn("## Invalid Summaries", audit.markdown_summary(report))

    def test_markdown_prints_missing_for_absent_optional_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-clock-switch-legacy", {
                "status": "pass",
                "samples": 4,
                "started_at": "2026-06-23T00:00:00Z",
                "finished_at": "2026-06-23T00:01:00Z",
                "min_raw_notification_delta": 18,
                "max_disconnect_delta": 0,
                "max_hr_continuity_delta": 0,
                "flags": [],
            })

            markdown = audit.markdown_summary(audit.evaluate(root))

            self.assertIn("min_accepted_delta=`missing`", markdown)
            self.assertNotIn("min_accepted_delta=`None`", markdown)

    def test_cli_writes_markdown_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "logs"
            out = Path(tmp) / "audit" / "report.md"

            result = subprocess.run(
                [
                    sys.executable,
                    "tools/audit_realtime_ble_validation.py",
                    "--root",
                    str(root),
                    "--markdown",
                    "--out",
                    str(out),
                ],
                cwd=Path(__file__).resolve().parent,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

            self.assertEqual(result.returncode, 1)
            text = out.read_text(encoding="utf-8")
            self.assertIn("# Realtime BLE Validation Audit", text)
            self.assertIn("Next command:", text)

    def test_cli_allows_incomplete_when_archiving_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "logs"
            out = Path(tmp) / "audit" / "report.md"

            result = subprocess.run(
                [
                    sys.executable,
                    "tools/audit_realtime_ble_validation.py",
                    "--root",
                    str(root),
                    "--markdown",
                    "--out",
                    str(out),
                    "--allow-incomplete",
                ],
                cwd=Path(__file__).resolve().parent,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

            self.assertEqual(result.returncode, 0)
            self.assertIn("Status: `incomplete`", out.read_text(encoding="utf-8"))

    def test_cli_writes_json_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "logs"
            out = Path(tmp) / "audit" / "report.json"

            result = subprocess.run(
                [
                    sys.executable,
                    "tools/audit_realtime_ble_validation.py",
                    "--root",
                    str(root),
                    "--out",
                    str(out),
                ],
                cwd=Path(__file__).resolve().parent,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

            self.assertEqual(result.returncode, 1)
            report = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "incomplete")
            self.assertIn("daytime_worn_monitor", report["requirements"])

    def test_daytime_requires_state_pull_continuity_not_just_green_ticks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-daytime-weak", passing_stream(
                state_pull={
                    "status": "ok",
                    "fields": {
                        "active_journal_freshness": "stale",
                        "active_journal_continuity_status": "stalled",
                        "active_journal_duration_s": "150",
                        "active_journal_samples": "158",
                        "file_durability_status": "saved_sessions_present",
                    },
                },
            ))

            report = audit.evaluate(root)
            blockers = report["requirements"]["daytime_worn_monitor"]["blockers"]

            self.assertIn("active_journal_not_fresh", blockers)
            self.assertIn("active_journal_not_active", blockers)
            self.assertIn("active_journal_duration_under_2h", blockers)

    def test_daytime_rejects_explicit_not_worn_monitor(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-daytime-not-worn", passing_stream(
                worn_expected=False,
                state_pull=passing_state(),
            ))

            report = audit.evaluate(root)
            blockers = report["requirements"]["daytime_worn_monitor"]["blockers"]

            self.assertIn("monitor_ran_not_worn", blockers)

    def test_daytime_rejects_future_summary_without_accepted_progress(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-daytime-no-accepted", passing_stream(
                min_accepted_sample_delta=0,
                state_pull=passing_state(),
            ))

            report = audit.evaluate(root)
            blockers = report["requirements"]["daytime_worn_monitor"]["blockers"]

            self.assertIn("no_positive_accepted_delta_on_every_tick", blockers)

    def test_app_switch_rejects_explicit_not_worn_monitor(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-clock-switch-not-worn", passing_app_switch(
                worn_expected=False,
            ))

            report = audit.evaluate(root)
            blockers = report["requirements"]["app_switch"]["blockers"]

            self.assertIn("monitor_ran_not_worn", blockers)

    def test_app_switch_requires_current_lifecycle_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-clock-switch-old-code", passing_stream(
                samples=4,
                started_at="2026-06-23T00:00:00Z",
                finished_at="2026-06-23T00:01:00Z",
                planned_interval_s=20,
            ))

            report = audit.evaluate(root)
            blockers = report["requirements"]["app_switch"]["blockers"]

            self.assertEqual(report["requirements"]["app_switch"]["status"], "incomplete")
            self.assertIn("app_switch_evidence_before_background_supervisor_resume", blockers)

    def test_sustained_silence_allows_expected_off_wrist_no_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-sustained-silence-off-wrist", {
                "status": "fail",
                "samples": 7,
                "state_pull": passing_state(),
                "min_raw_notification_delta": 0,
                "max_disconnect_delta": 1,
                "max_hr_continuity_delta": 1,
                "flags": ["NO_NEW_DATA", "ZERO_CONTACT"],
                "events": {"1": ["sustained_silence_start"], "3": ["sustained_silence_reseat"]},
                "event_outcomes": [{
                    "events": ["sustained_silence_reseat"],
                    "status": "recovered",
                    "next_raw_notification_delta": 42,
                    "next_disconnect_delta": 1,
                    "next_hr_continuity_delta": 1,
                }],
            })

            report = audit.evaluate(root)

            self.assertEqual(report["requirements"]["sustained_silence_reseat"]["status"], "pass")

    def test_brief_contact_loss_requires_state_pull(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-brief-contact-loss-no-state", passing_stream(
                samples=5,
                events={"1": ["brief_contact_loss_start"], "2": ["brief_contact_loss_reseat"]},
                event_outcomes=[{
                    "events": ["brief_contact_loss_reseat"],
                    "status": "recovered",
                    "next_raw_notification_delta": 70,
                    "next_disconnect_delta": 0,
                    "next_hr_continuity_delta": 0,
                }],
            ))

            report = audit.evaluate(root)
            blockers = report["requirements"]["brief_contact_loss"]["blockers"]

            self.assertIn("missing_ok_state_pull", blockers)

    def test_sustained_silence_requires_state_pull(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-sustained-silence-no-state", {
                "status": "fail",
                "samples": 7,
                "min_raw_notification_delta": 0,
                "max_disconnect_delta": 1,
                "max_hr_continuity_delta": 1,
                "flags": ["NO_NEW_DATA", "ZERO_CONTACT"],
                "events": {"1": ["sustained_silence_start"], "3": ["sustained_silence_reseat"]},
                "event_outcomes": [{
                    "events": ["sustained_silence_reseat"],
                    "status": "recovered",
                    "next_raw_notification_delta": 42,
                    "next_disconnect_delta": 1,
                    "next_hr_continuity_delta": 1,
                }],
            })

            report = audit.evaluate(root)
            blockers = report["requirements"]["sustained_silence_reseat"]["blockers"]

            self.assertIn("missing_ok_state_pull", blockers)

    def test_sustained_silence_still_rejects_churn(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-sustained-silence-churn", {
                "status": "fail",
                "samples": 7,
                "state_pull": passing_state(),
                "min_raw_notification_delta": 0,
                "max_disconnect_delta": 3,
                "max_hr_continuity_delta": 0,
                "flags": ["NO_NEW_DATA"],
                "events": {"1": ["sustained_silence_start"], "3": ["sustained_silence_reseat"]},
                "event_outcomes": [{
                    "events": ["sustained_silence_reseat"],
                    "status": "recovered",
                    "next_raw_notification_delta": 42,
                    "next_disconnect_delta": 3,
                    "next_hr_continuity_delta": 0,
                }],
            })

            report = audit.evaluate(root)
            blockers = report["requirements"]["sustained_silence_reseat"]["blockers"]

            self.assertIn("disconnect_churn", blockers)
            self.assertIn("event_disconnect_churn_sustained_silence_reseat", blockers)

    def test_sustained_silence_rejects_unexpected_keepalive_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_summary(root, "rt-sustained-silence-keepalive-flat", {
                "status": "fail",
                "samples": 7,
                "state_pull": passing_state(),
                "min_raw_notification_delta": 0,
                "max_disconnect_delta": 1,
                "max_hr_continuity_delta": 1,
                "flags": ["NO_NEW_DATA", "ZERO_CONTACT", "KEEPALIVE_NOT_ADVANCING"],
                "events": {"1": ["sustained_silence_start"], "3": ["sustained_silence_reseat"]},
                "event_outcomes": [{
                    "events": ["sustained_silence_reseat"],
                    "status": "recovered",
                    "next_raw_notification_delta": 42,
                    "next_disconnect_delta": 1,
                    "next_hr_continuity_delta": 1,
                }],
            })

            report = audit.evaluate(root)
            blockers = report["requirements"]["sustained_silence_reseat"]["blockers"]

            self.assertIn("unexpected_flags_KEEPALIVE_NOT_ADVANCING", blockers)


if __name__ == "__main__":
    unittest.main()
