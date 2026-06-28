#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
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
        "active_duration_nondecreasing": True,
        "active_hr_nondecreasing": True,
        "active_rr_nondecreasing": True,
        "battery_drop_from_first_percent": -12.0,
        "app_commit": current_test_commit(path),
        "monitor_started_at": "2026-06-22T00:00:00Z",
        "monitor_finished_at": "2026-06-22T10:00:00Z",
    }), encoding="utf-8")


def write_passing_accessibility_performance(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    trace = path.parent / "trace.trace"
    trace.parent.mkdir(parents=True, exist_ok=True)
    trace.write_text("placeholder trace artifact", encoding="utf-8")
    audit_handoff_status.trace_toc_sidecar(trace).write_text("""
<?xml version="1.0"?>
<trace-toc>
  <run number="1">
    <info>
      <target>
        <device platform="iOS" model="iPhone 15 Pro" name="Aman's iPhone" os-version="27.0" uuid="DEVICE"/>
        <process type="attached" return-exit-status="0" name="Atria" pid="20471" termination-reason="exit(0)"/>
      </target>
      <summary>
        <duration>11.3</duration>
        <template-name>Time Profiler</template-name>
      </summary>
    </info>
  </run>
</trace-toc>
""".strip(), encoding="utf-8")
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


def write_ready_device_pull(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join([
        "process_status=running",
        "official_whoop_coexistence_risk=0",
        "active_journal_final_status=ok",
        "active_journal_continuity_status=active",
        "active_journal_rr_status=rr_present",
        "active_journal_rr_gate_b_local_ready=1",
        "active_journal_rr_raw_beats=502",
        "active_journal_rr_corrected_beats=502",
        "active_journal_rr_kept_percent=100",
        "active_journal_rr_max_gap_s=2.0",
        "active_journal_rr_gate_b_local_blocker=none_reference_still_required",
        "battery_level=75",
        "battery_charge_status=notCharging",
        "battery_is_charging=0",
        "battery_usable=1",
        "",
    ]), encoding="utf-8")


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
    def test_accessibility_visual_evidence_helper_is_non_invasive(self):
        script = (Path(__file__).resolve().parent / "tools" / "capture_accessibility_visual_evidence.sh").read_text(encoding="utf-8")

        for required in [
            "xcrun xctrace record",
            "xcrun xctrace export",
            "--toc",
            "${trace_path}.toc.xml",
            "--attach \"$pid\"",
            "devicectl device capture screenshot",
            "devicectl device settings appearance",
            "prepare_accessibility_performance_evidence.py",
            "--all-accessibility-checks-pass",
            "--dashboard-scroll-fps",
            "Final mode requires --dashboard-scroll-fps from a real measured scroll pass.",
        ]:
            self.assertIn(required, script)

        for forbidden in [
            "device install app",
            "device process launch",
            "device process terminate",
            "live_device_debug.sh",
        ]:
            self.assertNotIn(forbidden, script)

    def test_dashboard_scroll_performance_helper_is_physical_and_non_invasive(self):
        script = (Path(__file__).resolve().parent / "tools" / "capture_dashboard_scroll_performance.sh").read_text(encoding="utf-8")

        for required in [
            "xcrun xctrace record",
            "--template 'SwiftUI'",
            "--instrument 'Core Animation FPS'",
            "--instrument 'Hitches'",
            "--instrument 'Time Profiler'",
            "devicectl device capture screen-record",
            "--attach \"$pid\"",
            "core-animation-fps-estimate",
            "dashboard-scroll.fps.xml",
            "dashboard-scroll.fps.txt",
            "Extracted Core Animation FPS max",
            "--xctrace-stop-grace",
            "Another xctrace record process is already running",
            "Stop stale Instruments captures before starting dashboard scroll proof.",
            "wait_with_timeout",
            "%s did not finish after %ss",
            "--measured-fps",
            "Final mode requires measured FPS from the xctrace FPS table or --measured-fps override.",
            "prepare_accessibility_performance_evidence.py",
            "--dashboard-scroll-fps",
        ]:
            self.assertIn(required, script)

        for forbidden in [
            "device install app",
            "device process launch",
            "device process terminate",
            "live_device_debug.sh",
        ]:
            self.assertNotIn(forbidden, script)

    def test_running_long_wear_progress_reports_eta_and_remaining_samples(self):
        progress = audit_handoff_status.running_long_wear_progress(
            {
                "planned_samples": 11,
                "planned_duration_s": 36_000,
                "planned_interval_s": 3_600,
                "monitor_started_at": "2026-06-27T23:00:00Z",
            },
            2,
            now=datetime(2026, 6, 28, 0, 30, tzinfo=timezone.utc),
        )

        self.assertEqual(progress["running_elapsed_s"], 5_400)
        self.assertEqual(progress["running_remaining_samples"], 9)
        self.assertEqual(progress["running_next_sample_due_at"], "2026-06-28T01:00:00Z")
        self.assertEqual(progress["running_expected_finish_at"], "2026-06-28T09:00:00Z")
        self.assertFalse(progress["running_sample_overdue"])
        self.assertEqual(progress["running_next_sample_overdue_s"], 0.0)

    def test_running_long_wear_progress_flags_overdue_sample_after_grace(self):
        progress = audit_handoff_status.running_long_wear_progress(
            {
                "planned_samples": 11,
                "planned_duration_s": 36_000,
                "planned_interval_s": 3_600,
                "monitor_started_at": "2026-06-27T23:00:00Z",
            },
            1,
            now=datetime(2026, 6, 28, 0, 15, tzinfo=timezone.utc),
        )

        self.assertEqual(progress["running_next_sample_due_at"], "2026-06-28T00:00:00Z")
        self.assertEqual(progress["running_next_sample_overdue_s"], 900.0)
        self.assertTrue(progress["running_sample_overdue"])

    def test_long_wear_launchctl_label_matches_detached_monitor_format(self):
        self.assertEqual(
            audit_handoff_status.launchctl_long_wear_label("overnight handoff/21"),
            "com.adidshaft.atria.longwear.overnight-handoff-21",
        )
        self.assertEqual(
            audit_handoff_status.launchctl_long_wear_label(""),
            "com.adidshaft.atria.longwear.run",
        )

    def test_parse_launchctl_service_extracts_running_monitor_facts(self):
        parsed = audit_handoff_status.parse_launchctl_service("\n".join([
            "state = running",
            "runs = 1",
            "pid = 52971",
            "last exit code = (never exited)",
            "state = active",
        ]))

        self.assertEqual(parsed["launchctl_status"], "running")
        self.assertEqual(parsed["launchctl_state"], "running")
        self.assertEqual(parsed["launchctl_pid"], 52971)
        self.assertEqual(parsed["launchctl_runs"], 1)
        self.assertEqual(parsed["launchctl_last_exit"], "(never exited)")

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

    def test_final_long_wear_trend_fields_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)

            physical = audit_handoff_status.evaluate_physical_long_wear(repo, summary)
            markdown = audit_handoff_status.markdown_summary({
                "status": "not_complete",
                "local_status": "pass",
                "physical_long_wear": physical,
                "latest_device_pull": {"status": "missing", "summary": "missing"},
                "accessibility_performance": {"status": "missing", "summary": "missing"},
                "external_reference_status": "skipped",
                "blockers": ["accessibility_performance_proof"],
            })

        self.assertTrue(physical["active_duration_nondecreasing"])
        self.assertTrue(physical["active_hr_nondecreasing"])
        self.assertTrue(physical["active_rr_nondecreasing"])
        self.assertEqual(physical["battery_drop_from_first_percent"], -12.0)
        self.assertIn("- Active HR nondecreasing: `True`", markdown)
        self.assertIn("- Battery drop from first percent: `-12`", markdown)

    def test_final_long_wear_trends_fall_back_to_sibling_samples_jsonl(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            data = json.loads(summary.read_text(encoding="utf-8"))
            for key in [
                "active_duration_nondecreasing",
                "active_hr_nondecreasing",
                "active_rr_nondecreasing",
                "battery_drop_from_first_percent",
            ]:
                data.pop(key, None)
            summary.write_text(json.dumps(data), encoding="utf-8")
            (summary.parent / "samples.jsonl").write_text("\n".join([
                json.dumps({
                    "sample": 0,
                    "active_journal": {
                        "duration_s": 100.0,
                        "accepted_hr": 100,
                        "delta_rr": 95,
                        "battery": 80,
                    },
                }),
                json.dumps({
                    "sample": 1,
                    "active_journal": {
                        "duration_s": 3700.0,
                        "accepted_hr": 3600,
                        "delta_rr": 3300,
                        "battery": 78,
                    },
                }),
                "",
            ]), encoding="utf-8")

            physical = audit_handoff_status.evaluate_physical_long_wear(repo, summary)

        self.assertTrue(physical["active_duration_nondecreasing"])
        self.assertTrue(physical["active_hr_nondecreasing"])
        self.assertTrue(physical["active_rr_nondecreasing"])
        self.assertEqual(physical["battery_drop_from_first_percent"], -2.0)

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
        self.assertIn("missing_long_wear_app_commit", report["blockers"])

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
        self.assertIn("missing_long_wear_app_commit", report["blockers"])
        self.assertIn("missing_long_wear_monitor_started_at", report["blockers"])
        self.assertIn("missing_long_wear_monitor_finished_at", report["blockers"])

    def test_long_wear_app_commit_must_match_repo_head(self):
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
            data = json.loads(summary.read_text(encoding="utf-8"))
            data["app_commit"] = "0" * 40
            summary.write_text(json.dumps(data), encoding="utf-8")
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["physical_long_wear"]["status"], "fail")
        self.assertIn("long_wear_app_commit_mismatch", report["blockers"])

    def test_long_wear_app_commit_can_precede_proof_only_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "app"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            app_commit = current_test_commit(repo / "tools/monitor_long_wear.py")
            (repo / "tools/monitor_long_wear.py").write_text("proof tooling\n", encoding="utf-8")
            subprocess.run(["git", "add", "tools/monitor_long_wear.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "proof tooling"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            (repo / ".gitignore").write_text("tmp/\n", encoding="utf-8")
            subprocess.run(["git", "add", ".gitignore"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "ignore local diagnostics"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            data = json.loads(summary.read_text(encoding="utf-8"))
            data["app_commit"] = app_commit
            data["monitor_commit"] = current_test_commit(repo / "tools/monitor_long_wear.py")
            summary.write_text(json.dumps(data), encoding="utf-8")
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)

        self.assertNotIn("long_wear_app_commit_mismatch", report["blockers"])

    def test_long_wear_app_commit_still_blocks_after_app_source_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "app"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            app_commit = current_test_commit(repo / "Atria/Atria/AtriaBLEManager.swift")
            (repo / "Atria/Atria/AtriaBLEManager.swift").write_text("app source change\n", encoding="utf-8")
            subprocess.run(["git", "add", "Atria/Atria/AtriaBLEManager.swift"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "app source"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            data = json.loads(summary.read_text(encoding="utf-8"))
            data["app_commit"] = app_commit
            summary.write_text(json.dumps(data), encoding="utf-8")
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)

        self.assertIn("long_wear_app_commit_mismatch", report["blockers"])

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

    def test_running_overnight_samples_are_reported_before_final_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            old_summary = repo / "logs/live-device/long-wear-monitor/smoke/summary.json"
            write_passing_long_wear_summary(old_summary)
            running = repo / "logs/live-device/long-wear-monitor/overnight-current/samples.jsonl"
            running.parent.mkdir(parents=True)
            (running.parent / "run.json").write_text(json.dumps({
                "label": "overnight-current",
                "preset": "overnight",
                "planned_samples": 11,
                "planned_duration_s": 36_000,
                "app_commit": "installed-app",
                "monitor_commit": "monitor-tooling",
                "monitor_started_at": "2026-06-27T23:19:29Z",
            }), encoding="utf-8")
            running.write_text(json.dumps({
                "sample": 0,
                "captured_at": "20260627T231930Z",
                "log": "/tmp/pull.log",
                "active_journal": {
                    "status": "ok",
                    "thermal": "nominal",
                    "duration_s": 4978.3,
                    "accepted_hr": 5179,
                    "delta_rr": 4653,
                    "segments": 172,
                    "battery": 74,
                    "latest_bpm": 62,
                },
                "sessions": {"status": "ok", "recent_span_s": 43578.6, "recent_coverage_percent": 48.8},
            }) + "\n", encoding="utf-8")

            physical = audit_handoff_status.evaluate_physical_long_wear(repo)

        self.assertEqual(physical["status"], "in_progress")
        self.assertEqual(physical["acceptance_status"], "running")
        self.assertIn("overnight_summary_pending", physical["audit_blockers"])
        self.assertEqual(physical["running_samples"], 1)
        self.assertEqual(physical["label"], "overnight-current")
        self.assertEqual(physical["launchctl_label"], "com.adidshaft.atria.longwear.overnight-current")
        self.assertEqual(physical["latest_recent_session_span_s"], 43578.6)
        self.assertEqual(physical["app_commit"], "installed-app")
        self.assertEqual(physical["monitor_commit"], "monitor-tooling")
        self.assertEqual(physical["monitor_started_at"], "2026-06-27T23:19:29Z")
        self.assertEqual(physical["latest_active_status"], "ok")
        self.assertEqual(physical["latest_active_duration_s"], 4978.3)
        self.assertEqual(physical["latest_active_accepted_hr"], 5179)
        self.assertEqual(physical["latest_active_delta_rr"], 4653)
        self.assertEqual(physical["latest_active_segments"], 172)
        self.assertEqual(physical["latest_active_battery"], 74)
        self.assertEqual(physical["latest_active_bpm"], 62)
        self.assertEqual(physical["active_duration_nondecreasing"], "pending")
        self.assertEqual(physical["active_hr_nondecreasing"], "pending")
        self.assertEqual(physical["active_rr_nondecreasing"], "pending")
        self.assertEqual(physical["battery_drop_from_first_percent"], 0.0)
        self.assertEqual(physical["running_remaining_samples"], 10)
        self.assertEqual(physical["running_next_sample_due_at"], "2026-06-28T00:19:29Z")
        self.assertEqual(physical["running_expected_finish_at"], "2026-06-28T09:19:29Z")

    def test_running_overnight_reports_sample_trends_from_jsonl(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            running = repo / "logs/live-device/long-wear-monitor/overnight-current/samples.jsonl"
            running.parent.mkdir(parents=True)
            (running.parent / "run.json").write_text(json.dumps({
                "label": "overnight-current",
                "preset": "overnight",
                "planned_samples": 11,
                "planned_duration_s": 36_000,
                "monitor_started_at": "2026-06-27T23:19:29Z",
            }), encoding="utf-8")
            running.write_text("\n".join([
                json.dumps({
                    "sample": 0,
                    "captured_at": "20260627T231930Z",
                    "active_journal": {
                        "status": "ok",
                        "thermal": "nominal",
                        "duration_s": 100.0,
                        "accepted_hr": 100,
                        "delta_rr": 90,
                        "battery": 80,
                    },
                    "sessions": {"status": "ok"},
                }),
                json.dumps({
                    "sample": 1,
                    "captured_at": "20260628T001930Z",
                    "active_journal": {
                        "status": "ok",
                        "thermal": "nominal",
                        "duration_s": 3700.0,
                        "accepted_hr": 3600,
                        "delta_rr": 3300,
                        "battery": 78,
                    },
                    "sessions": {"status": "ok"},
                }),
                "",
            ]), encoding="utf-8")

            physical = audit_handoff_status.evaluate_physical_long_wear(repo)

        self.assertTrue(physical["active_duration_nondecreasing"])
        self.assertTrue(physical["active_hr_nondecreasing"])
        self.assertTrue(physical["active_rr_nondecreasing"])
        self.assertEqual(physical["battery_drop_from_first_percent"], -2.0)
        self.assertEqual(physical["running_samples"], 2)

    def test_running_overnight_flags_overdue_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            running = repo / "logs/live-device/long-wear-monitor/overnight-current/samples.jsonl"
            running.parent.mkdir(parents=True)
            (running.parent / "run.json").write_text(json.dumps({
                "label": "overnight-current",
                "preset": "overnight",
                "planned_samples": 11,
                "planned_duration_s": 36_000,
                "planned_interval_s": 3_600,
                "monitor_started_at": "2020-01-01T00:00:00Z",
            }), encoding="utf-8")
            running.write_text(json.dumps({
                "sample": 0,
                "captured_at": "20200101T000000Z",
                "active_journal": {"status": "ok", "thermal": "nominal"},
                "sessions": {"status": "ok"},
            }) + "\n", encoding="utf-8")

            physical = audit_handoff_status.evaluate_physical_long_wear(repo)

        self.assertTrue(physical["running_sample_overdue"])
        self.assertIn("overnight_sample_overdue", physical["audit_blockers"])

    def test_running_overnight_flags_stopped_launchctl_service(self):
        original = audit_handoff_status.inspect_launchctl_service
        audit_handoff_status.inspect_launchctl_service = lambda label: {
            "launchctl_status": "not_running",
            "launchctl_state": "waiting",
            "launchctl_pid": "missing",
            "launchctl_runs": 1,
            "launchctl_last_exit": "1",
        }
        try:
            with tempfile.TemporaryDirectory() as tmp:
                repo = Path(tmp)
                running = repo / "logs/live-device/long-wear-monitor/overnight-current/samples.jsonl"
                running.parent.mkdir(parents=True)
                (running.parent / "run.json").write_text(json.dumps({
                    "label": "overnight-current",
                    "preset": "overnight",
                    "planned_samples": 11,
                    "planned_duration_s": 36_000,
                    "monitor_started_at": "2026-06-27T23:19:29Z",
                }), encoding="utf-8")
                running.write_text(json.dumps({
                    "sample": 0,
                    "captured_at": "20260627T231930Z",
                    "active_journal": {"status": "ok", "thermal": "nominal"},
                    "sessions": {"status": "ok"},
                }) + "\n", encoding="utf-8")

                physical = audit_handoff_status.evaluate_physical_long_wear(repo)
        finally:
            audit_handoff_status.inspect_launchctl_service = original

        self.assertEqual(physical["launchctl_status"], "not_running")
        self.assertIn("overnight_monitor_not_running", physical["audit_blockers"])

    def test_markdown_summary_includes_current_blocking_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            summary.parent.mkdir(parents=True)
            summary.write_text(json.dumps({
                "acceptance_status": "fail",
                "acceptance_blockers": ["session_span", "session_coverage", "thermal"],
                "acceptance_diagnostics": {
                    "session_span": {
                        "observed_s": 2731.1,
                        "required_min_s": 28800,
                        "ok": False,
                    },
                    "session_coverage": {
                        "observed_percent": 50.0,
                        "required_min_percent": 85.0,
                        "ok": False,
                    },
                },
                "thermal_states": ["serious"],
                "battery_delta": 0,
                "latest_recent_session_span_s": 2731.1,
                "latest_recent_session_coverage_percent": 50.0,
            }), encoding="utf-8")

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)
            markdown = audit_handoff_status.markdown_summary(report)

        self.assertIn("# Atria Handoff Status", markdown)
        self.assertIn("- Status: `not_complete`", markdown)
        self.assertIn("- Local checks: `pass`", markdown)
        self.assertIn("- External reference: `skipped`", markdown)
        self.assertIn("## Next Required Evidence", markdown)
        self.assertIn("Wait for the overnight long-wear monitor to write `summary.json`", markdown)
        self.assertIn("`session_span`: observed_s=2731.1, required_min_s=28800, ok=False", markdown)
        self.assertIn("`session_coverage`: observed_percent=50, required_min_percent=85, ok=False", markdown)
        self.assertIn("`missing_accessibility_performance_summary`", markdown)

    def test_markdown_summary_includes_latest_device_pull(self):
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
            pull = repo / "tmp/diag/current/pull-summary.txt"
            write_ready_device_pull(pull)

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)
            markdown = audit_handoff_status.markdown_summary(report)

        latest_pull = report["latest_device_pull"]
        self.assertEqual(latest_pull["status"], "ok")
        self.assertEqual(latest_pull["active_journal_rr_gate_b_local_ready"], "1")
        self.assertIn("- Latest device pull: `ok`", markdown)
        self.assertIn("## Latest Device Pull", markdown)
        self.assertIn("- Official WHOOP coexistence risk: `0`", markdown)
        self.assertIn("- Local RR ready: `1`", markdown)
        self.assertIn("raw `502`, corrected `502`, kept `100%`, max gap `2.0s`", markdown)
        self.assertIn("- Strap battery: `75%`, charge `notCharging`, charging `0`, usable `1`", markdown)

    def test_latest_device_pull_attention_when_rr_gate_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            pull = repo / "tmp/diag/current/pull-summary.txt"
            write_ready_device_pull(pull)
            text = pull.read_text(encoding="utf-8")
            text = text.replace("active_journal_rr_gate_b_local_ready=1",
                                "active_journal_rr_gate_b_local_ready=0")
            text = text.replace("active_journal_rr_max_gap_s=2.0",
                                "active_journal_rr_max_gap_s=4.0")
            text = text.replace("active_journal_rr_gate_b_local_blocker=none_reference_still_required",
                                "active_journal_rr_gate_b_local_blocker=rr_gap_4.0s_gt_3s")
            pull.write_text(text, encoding="utf-8")

            latest_pull = audit_handoff_status.evaluate_latest_device_pull(repo)

        self.assertEqual(latest_pull["status"], "attention")
        self.assertEqual(latest_pull["active_journal_rr_gate_b_local_ready"], "0")
        self.assertEqual(latest_pull["active_journal_rr_gate_b_local_blocker"], "rr_gap_4.0s_gt_3s")

    def test_latest_device_pull_prefers_newer_goal_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            old_pull = repo / "tmp/diag/current/pull-summary.txt"
            new_pull = repo / "artifacts/goal-21-state-current/pull-summary.txt"
            write_ready_device_pull(old_pull)
            write_ready_device_pull(new_pull)
            text = new_pull.read_text(encoding="utf-8")
            text = text.replace("battery_level=75", "battery_level=58")
            new_pull.write_text(text, encoding="utf-8")
            os.utime(old_pull, (1, 1))
            os.utime(new_pull, (2, 2))

            latest_pull = audit_handoff_status.evaluate_latest_device_pull(repo)

        self.assertEqual(latest_pull["summary"], str(new_pull))
        self.assertEqual(latest_pull["battery_level"], "58")

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

    def test_accessibility_performance_missing_final_reports_draft(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            draft_trace = repo / "docs/evidence/accessibility-performance/trace-live.trace"
            draft_trace.parent.mkdir(parents=True)
            draft_trace.write_text("trace", encoding="utf-8")
            draft = repo / "docs/evidence/accessibility-performance/summary.draft.json"
            draft.write_text(json.dumps({
                "device": "iPhone 15 Pro",
                "accessibility_checks": {
                    "dark_mode": True,
                    "increase_contrast": True,
                    "light_mode": True,
                    "reduce_motion": True,
                    "reduce_transparency": True,
                },
                "dashboard_scroll_fps": 0,
                "instruments_trace": "docs/evidence/accessibility-performance/trace-live.trace",
                "measured_at": "2026-06-28T13:23:55Z",
                "app_commit": "abc123",
                "app_build": "Atria 1.0 (1)",
            }), encoding="utf-8")

            report = audit_handoff_status.evaluate(repo, summary, skip_external_reference=True)
            markdown = audit_handoff_status.markdown_summary(report)

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["accessibility_performance"]["status"], "missing")
        self.assertIn("missing_accessibility_performance_summary", report["blockers"])
        draft_report = report["accessibility_performance"]["draft"]
        self.assertEqual(draft_report["status"], "present")
        self.assertEqual(draft_report["dashboard_scroll_fps"], 0)
        self.assertTrue(draft_report["instruments_trace_exists"])
        self.assertIn("### Accessibility Draft Evidence", markdown)
        self.assertIn("Draft dashboard scroll fps: `0`", markdown)
        self.assertIn("Draft passed checks: `dark_mode, increase_contrast, light_mode, reduce_motion, reduce_transparency`", markdown)

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

    def test_next_evidence_items_name_measured_scroll_fps_finalization(self):
        report = {
            "blockers": ["dashboard_scroll_fps", "accessibility_performance_proof"],
            "physical_long_wear": {"status": "pass"},
        }

        items = audit_handoff_status.next_evidence_items(report)

        self.assertEqual(len(items), 1)
        self.assertIn("Measure real dashboard scroll FPS", items[0])
        self.assertIn("capture_dashboard_scroll_performance.sh", items[0])
        self.assertIn("--measured-fps <fps> --final", items[0])
        self.assertIn("fps >= 58", items[0])

    def test_next_evidence_items_name_draft_trace_finalization_when_summary_missing(self):
        report = {
            "blockers": ["missing_accessibility_performance_summary", "accessibility_performance_proof"],
            "accessibility_performance": {
                "status": "missing",
                "draft": {
                    "status": "present",
                    "instruments_trace": "docs/evidence/accessibility-performance/dashboard-scroll.trace",
                },
            },
        }

        items = audit_handoff_status.next_evidence_items(report)

        self.assertEqual(len(items), 1)
        self.assertIn("Finalize the physical accessibility/performance proof", items[0])
        self.assertIn("docs/evidence/accessibility-performance/dashboard-scroll.trace", items[0])
        self.assertIn("prepare_accessibility_performance_evidence.py", items[0])
        self.assertIn("--all-accessibility-checks-pass --final", items[0])
        self.assertIn("Do not write final `summary.json` from an assumed FPS", items[0])

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

    def test_accessibility_performance_accepts_dashboard_scroll_swiftui_trace(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)
            trace = repo / "docs/evidence/accessibility-performance/trace.trace"
            audit_handoff_status.trace_toc_sidecar(trace).write_text("""
<?xml version="1.0"?>
<trace-toc>
  <run number="1">
    <info>
      <target>
        <device model="iPhone 15 Pro"/>
        <process name="Atria"/>
      </target>
      <summary>
        <duration>12.0</duration>
        <template-name>SwiftUI</template-name>
      </summary>
    </info>
  </run>
</trace-toc>
""".strip(), encoding="utf-8")

            report = audit_handoff_status.evaluate(
                repo,
                summary,
                skip_external_reference=True,
                accessibility_performance_path=accessibility,
            )

        self.assertEqual(report["accessibility_performance"]["status"], "pass")
        self.assertNotIn("instruments_trace_template", report["blockers"])

    def test_accessibility_performance_trace_toc_must_match_device_app_and_template(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)
            trace = repo / "docs/evidence/accessibility-performance/trace.trace"
            audit_handoff_status.trace_toc_sidecar(trace).write_text("""
<?xml version="1.0"?>
<trace-toc>
  <run number="1">
    <info>
      <target>
        <device model="iPhone 14"/>
        <process name="OtherApp"/>
      </target>
      <summary>
        <duration>0</duration>
        <template-name>Allocations</template-name>
      </summary>
    </info>
  </run>
</trace-toc>
""".strip(), encoding="utf-8")

            report = audit_handoff_status.evaluate(
                repo,
                summary,
                skip_external_reference=True,
                accessibility_performance_path=accessibility,
            )

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["accessibility_performance"]["status"], "fail")
        self.assertIn("instruments_trace_device", report["blockers"])
        self.assertIn("instruments_trace_process", report["blockers"])
        self.assertIn("instruments_trace_template", report["blockers"])
        self.assertIn("instruments_trace_duration", report["blockers"])

    def test_accessibility_performance_trace_file_must_exist(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)
            trace = repo / "docs/evidence/accessibility-performance/trace.trace"
            trace.unlink()

            report = audit_handoff_status.evaluate(
                repo,
                summary,
                skip_external_reference=True,
                accessibility_performance_path=accessibility,
            )

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["accessibility_performance"]["status"], "fail")
        self.assertIn("missing_instruments_trace_file", report["blockers"])
        self.assertFalse(report["accessibility_performance"]["instruments_trace_exists"])

    def test_accessibility_performance_measured_at_must_be_utc_timestamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)
            data = json.loads(accessibility.read_text(encoding="utf-8"))
            data["measured_at"] = "June 22"
            accessibility.write_text(json.dumps(data), encoding="utf-8")

            report = audit_handoff_status.evaluate(
                repo,
                summary,
                skip_external_reference=True,
                accessibility_performance_path=accessibility,
            )

        self.assertEqual(report["status"], "not_complete")
        self.assertEqual(report["accessibility_performance"]["status"], "fail")
        self.assertIn("invalid_measured_at", report["blockers"])

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

    def test_accessibility_performance_app_commit_can_precede_proof_only_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "app"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            app_commit = current_test_commit(repo / "tools/prepare_accessibility_performance_evidence.py")
            (repo / "tools/prepare_accessibility_performance_evidence.py").write_text("proof tooling\n", encoding="utf-8")
            subprocess.run(["git", "add", "tools/prepare_accessibility_performance_evidence.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "proof tooling"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)
            data = json.loads(accessibility.read_text(encoding="utf-8"))
            data["app_commit"] = app_commit
            accessibility.write_text(json.dumps(data), encoding="utf-8")

            report = audit_handoff_status.evaluate(repo,
                                                   summary,
                                                   skip_external_reference=True,
                                                   accessibility_performance_path=accessibility)

        self.assertNotIn("app_commit_mismatch", report["blockers"])

    def test_accessibility_performance_app_commit_blocks_after_app_source_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            for rel in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                touch(repo, rel)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "app"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            app_commit = current_test_commit(repo / "Atria/Atria/AtriaBLEManager.swift")
            (repo / "Atria/Atria/AtriaBLEManager.swift").write_text("app source\n", encoding="utf-8")
            subprocess.run(["git", "add", "Atria/Atria/AtriaBLEManager.swift"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "app source"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            summary = repo / "logs/live-device/long-wear-monitor/check/summary.json"
            write_passing_long_wear_summary(summary)
            accessibility = repo / "docs/evidence/accessibility-performance/summary.json"
            write_passing_accessibility_performance(accessibility)
            data = json.loads(accessibility.read_text(encoding="utf-8"))
            data["app_commit"] = app_commit
            accessibility.write_text(json.dumps(data), encoding="utf-8")

            report = audit_handoff_status.evaluate(repo,
                                                   summary,
                                                   skip_external_reference=True,
                                                   accessibility_performance_path=accessibility)

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
