#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools import monitor_realtime_ble


class MonitorRealtimeBLETests(unittest.TestCase):
    def test_delta_uses_counter_keys(self):
        previous = {
            "atria.sample.rawNotifications": 10,
            "atria.sample.acceptedSamples": 8,
            "atria.link.disconnects": 2,
            "atria.watchdog.hrContinuityCount": 1,
        }
        current = {
            "atria.sample.rawNotifications": 15,
            "atria.sample.acceptedSamples": 12,
            "atria.link.disconnects": 3,
            "atria.watchdog.hrContinuityCount": 1,
        }

        delta = monitor_realtime_ble.compute_delta(previous, current)

        self.assertEqual(delta["atria.sample.rawNotifications"], 5)
        self.assertEqual(delta["atria.sample.acceptedSamples"], 4)
        self.assertEqual(delta["atria.link.disconnects"], 1)
        self.assertEqual(delta["atria.watchdog.hrContinuityCount"], 0)
        self.assertEqual(delta["atria.keepalive.ticks"], 0)

    def test_worn_sample_flags_silent_stall_and_zero_contact(self):
        delta = {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS}
        current = {
            "atria.sample.lastStatus": "zero_contact",
            "atria.link.lastStatus": "connected",
        }

        flags = monitor_realtime_ble.evaluate_sample(delta, current, worn=True)

        self.assertIn("NO_NEW_DATA", flags)
        self.assertIn("ZERO_CONTACT", flags)

    def test_not_worn_sample_allows_zero_contact(self):
        delta = {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS}
        current = {
            "atria.sample.lastStatus": "zero_contact",
            "atria.link.lastStatus": "connected",
        }

        flags = monitor_realtime_ble.evaluate_sample(delta, current, worn=False)

        self.assertNotIn("NO_NEW_DATA", flags)
        self.assertNotIn("ZERO_CONTACT", flags)

    def test_long_wear_allows_flat_keepalive_ticks_when_stream_advances(self):
        delta = {
            **{key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
            "atria.sample.rawNotifications": 12,
            "atria.sample.acceptedSamples": 12,
        }
        current = {
            "atria.sample.lastStatus": "accepted",
            "atria.link.lastStatus": "connected",
            "atria.longWear.enabled": True,
            "atria.keepalive.armed": True,
        }

        flags = monitor_realtime_ble.evaluate_sample(delta, current, worn=True)

        self.assertNotIn("KEEPALIVE_NOT_ADVANCING", flags)

    def test_long_wear_flags_flat_keepalive_ticks_when_stream_stalls(self):
        delta = {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS}
        current = {
            "atria.sample.lastStatus": "accepted",
            "atria.link.lastStatus": "connected",
            "atria.longWear.enabled": True,
            "atria.keepalive.armed": True,
        }

        flags = monitor_realtime_ble.evaluate_sample(delta, current, worn=True)

        self.assertIn("NO_NEW_DATA", flags)
        self.assertIn("KEEPALIVE_NOT_ADVANCING", flags)

    def test_long_wear_allows_advancing_keepalive_ticks(self):
        delta = {
            **{key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
            "atria.sample.rawNotifications": 12,
            "atria.sample.acceptedSamples": 12,
            "atria.keepalive.ticks": 2,
        }
        current = {
            "atria.sample.lastStatus": "accepted",
            "atria.link.lastStatus": "connected",
            "atria.longWear.enabled": True,
            "atria.keepalive.armed": True,
        }

        flags = monitor_realtime_ble.evaluate_sample(delta, current, worn=True)

        self.assertNotIn("KEEPALIVE_NOT_ADVANCING", flags)

    def test_summary_fails_when_any_tick_flags(self):
        samples = [
            {
                "current": {"atria.link.lastStatus": "connected"},
                "delta": {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
                "flags": [],
            },
            {
                "current": {"atria.link.lastStatus": "connected"},
                "delta": {
                    **{key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
                    "atria.sample.rawNotifications": 0,
                    "atria.link.disconnects": 0,
                    "atria.watchdog.hrContinuityCount": 0,
                },
                "flags": ["NO_NEW_DATA"],
            },
        ]

        summary = monitor_realtime_ble.summarize(samples, worn=True)

        self.assertEqual(summary["status"], "fail")
        self.assertEqual(summary["flags"], ["NO_NEW_DATA"])

    def test_summary_passes_when_only_baseline_has_zero_delta(self):
        baseline_delta = {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS}
        healthy_delta = {
            **{key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
            "atria.sample.rawNotifications": 12,
            "atria.sample.acceptedSamples": 12,
            "atria.link.disconnects": 0,
            "atria.watchdog.hrContinuityCount": 0,
        }
        samples = [
            {
                "current": {"atria.sample.lastStatus": "accepted", "atria.link.lastStatus": "connected"},
                "delta": baseline_delta,
                "flags": [],
            },
            {
                "current": {"atria.sample.lastStatus": "accepted", "atria.link.lastStatus": "connected"},
                "delta": healthy_delta,
                "flags": [],
            },
        ]

        summary = monitor_realtime_ble.summarize(samples, worn=True)

        self.assertEqual(summary["status"], "pass")
        self.assertEqual(summary["min_raw_notification_delta"], 12)
        self.assertEqual(summary["min_accepted_sample_delta"], 12)

    def test_pull_state_summary_keeps_continuity_fields(self):
        text = """
        process_name_status=atria
        official_whoop_process_status=running
        official_whoop_widget_process=1
        official_whoop_coexistence_risk=1
        link_last_auto_save_status=checkpointed_continuity
        link_last_auto_save_samples=8160
        link_last_auto_save_duration_s=7857
        active_journal_continuity_status=active
        active_journal_continuity_reason=fresh_journal
        latest_session_points=188
        live_stream_consistency_status=interrupted_not_file_loss
        noisy line without separator
        """

        fields = monitor_realtime_ble.parse_key_value_lines(text)
        compact = monitor_realtime_ble.compact_pull_state_summary(fields)

        self.assertEqual(compact["process_name_status"], "atria")
        self.assertEqual(compact["official_whoop_process_status"], "running")
        self.assertEqual(compact["official_whoop_widget_process"], "1")
        self.assertEqual(compact["official_whoop_coexistence_risk"], "1")
        self.assertEqual(compact["link_last_auto_save_status"], "checkpointed_continuity")
        self.assertEqual(compact["link_last_auto_save_samples"], "8160")
        self.assertEqual(compact["link_last_auto_save_duration_s"], "7857")
        self.assertEqual(compact["active_journal_continuity_status"], "active")
        self.assertEqual(compact["active_journal_continuity_reason"], "fresh_journal")
        self.assertEqual(compact["latest_session_points"], "188")
        self.assertEqual(compact["live_stream_consistency_status"], "interrupted_not_file_loss")
        self.assertNotIn("noisy line without separator", compact)

    def test_parse_sample_events_groups_by_sample(self):
        events = monitor_realtime_ble.parse_sample_events([
            "2:brief_contact_loss_start",
            "2:brief_contact_loss_reseat",
            "4:sustained_silence_start",
        ])

        self.assertEqual(events[2], ["brief_contact_loss_start", "brief_contact_loss_reseat"])
        self.assertEqual(events[4], ["sustained_silence_start"])

    def test_parse_sample_events_rejects_bad_format(self):
        with self.assertRaises(ValueError):
            monitor_realtime_ble.parse_sample_events(["brief_contact_loss_start"])

    def test_event_actions_for_known_stress_labels(self):
        actions = monitor_realtime_ble.event_actions_for([
            "brief_contact_loss_start",
            "unknown_label",
            "brief_contact_loss_reseat",
        ])

        self.assertEqual(actions, [
            "Loosen or lift the strap for about 30 seconds.",
            "Reseat the strap firmly now.",
        ])

    def test_event_outcomes_mark_recovered_next_sample(self):
        samples = [
            {
                "sample": 1,
                "events": ["brief_contact_loss_reseat"],
                "delta": {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
                "flags": [],
            },
            {
                "sample": 2,
                "delta": {
                    **{key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
                    "atria.sample.rawNotifications": 18,
                    "atria.sample.acceptedSamples": 18,
                    "atria.link.disconnects": 0,
                    "atria.watchdog.hrContinuityCount": 0,
                },
                "flags": [],
            },
        ]

        outcomes = monitor_realtime_ble.event_outcomes(samples)

        self.assertEqual(outcomes[0]["status"], "recovered")
        self.assertEqual(outcomes[0]["next_raw_notification_delta"], 18)
        self.assertEqual(outcomes[0]["next_disconnect_delta"], 0)

    def test_event_outcomes_mark_no_new_data_next_sample(self):
        samples = [
            {
                "sample": 1,
                "events": ["sustained_silence_reseat"],
                "delta": {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
                "flags": [],
            },
            {
                "sample": 2,
                "delta": {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
                "flags": ["NO_NEW_DATA"],
            },
        ]

        outcomes = monitor_realtime_ble.event_outcomes(samples)

        self.assertEqual(outcomes[0]["status"], "no_new_data_after_event")
        self.assertEqual(outcomes[0]["next_raw_notification_delta"], 0)

    def test_write_audit_snapshot_archives_markdown_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "realtime"
            run = root / "rt-clock-switch-ok"
            run.mkdir(parents=True)
            (run / "summary.json").write_text(json.dumps({
                "label": "rt-clock-switch-ok",
                "status": "pass",
                "samples": 4,
                "started_at": "2026-06-23T00:00:00Z",
                "finished_at": "2026-06-23T00:01:00Z",
                "min_raw_notification_delta": 18,
                "max_disconnect_delta": 0,
                "max_hr_continuity_delta": 0,
                "flags": [],
            }), encoding="utf-8")
            out = run / "audit.md"

            snapshot = monitor_realtime_ble.write_audit_snapshot(root, out)

            self.assertEqual(snapshot["status"], "incomplete")
            self.assertEqual(snapshot["summary_count"], 1)
            self.assertTrue(out.exists())
            text = out.read_text(encoding="utf-8")
            self.assertIn("# Realtime BLE Validation Audit", text)
            self.assertIn("rt-clock-switch-ok", text)

    def test_write_audit_snapshot_works_from_tools_script_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "realtime"
            run = root / "rt-clock-switch-ok"
            run.mkdir(parents=True)
            (run / "summary.json").write_text(json.dumps({
                "label": "rt-clock-switch-ok",
                "status": "pass",
                "samples": 4,
                "started_at": "2026-06-23T00:00:00Z",
                "finished_at": "2026-06-23T00:01:00Z",
                "min_raw_notification_delta": 18,
                "max_disconnect_delta": 0,
                "max_hr_continuity_delta": 0,
                "flags": [],
            }), encoding="utf-8")
            script = (
                "import pathlib, monitor_realtime_ble as m; "
                f"m.write_audit_snapshot(pathlib.Path({str(root)!r}), pathlib.Path({str(run / 'audit.md')!r}))"
            )

            result = subprocess.run(
                [sys.executable, "-c", script],
                cwd=Path(__file__).resolve().parent / "tools",
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertTrue((run / "audit.md").exists())

    def test_finalize_summary_refreshes_embedded_audit_after_snapshot_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "realtime"
            run = root / "rt-app-switch-pass"
            run.mkdir(parents=True)
            summary_path = run / "summary.json"
            calls = []
            original = monitor_realtime_ble.write_audit_snapshot

            def fake_write_audit_snapshot(audit_root, destination):
                payload = json.loads(summary_path.read_text(encoding="utf-8"))
                saw_snapshot = "audit_snapshot" in payload
                calls.append(saw_snapshot)
                destination.write_text(
                    "app_switch pass\n" if saw_snapshot else "app_switch missing_audit_snapshot\n",
                    encoding="utf-8",
                )
                return {
                    "status": "incomplete",
                    "path": str(destination),
                    "summary_count": 1,
                    "blockers": [] if saw_snapshot else ["app_switch:missing_audit_snapshot"],
                }

            try:
                monitor_realtime_ble.write_audit_snapshot = fake_write_audit_snapshot
                monitor_realtime_ble.finalize_summary(summary_path, {"status": "pass"}, root)
            finally:
                monitor_realtime_ble.write_audit_snapshot = original

            final = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertEqual(calls, [False, True])
            self.assertEqual(final["audit_snapshot"]["blockers"], [])
            self.assertIn("app_switch pass", (run / "audit.md").read_text(encoding="utf-8"))

    def test_command_string_quotes_monitor_arguments(self):
        command = monitor_realtime_ble.command_string([
            "tools/monitor_realtime_ble.py",
            "--label",
            "rt-daytime-test",
            "--event",
            "1:brief contact",
        ])

        self.assertIn("tools/monitor_realtime_ble.py", command)
        self.assertIn("--label rt-daytime-test", command)
        self.assertIn("'1:brief contact'", command)

    def test_invocation_string_records_effective_device_and_bundle(self):
        command = monitor_realtime_ble.invocation_string(
            ["tools/monitor_realtime_ble.py", "--label", "rt-daytime-test"],
            device="device with space",
            bundle="com.example.custom",
        )

        self.assertIn("ATRIA_DEVICE_ID='device with space'", command)
        self.assertIn("ATRIA_BUNDLE_ID=com.example.custom", command)
        self.assertIn("tools/monitor_realtime_ble.py --label rt-daytime-test", command)

    def test_invocation_string_keeps_default_command_clean(self):
        command = monitor_realtime_ble.invocation_string(
            ["tools/monitor_realtime_ble.py", "--samples", "2"],
            device=monitor_realtime_ble.DEFAULT_DEVICE,
            bundle=monitor_realtime_ble.DEFAULT_BUNDLE,
        )

        self.assertEqual(command, "tools/monitor_realtime_ble.py --samples 2")

    def test_git_commit_returns_current_commit(self):
        commit = monitor_realtime_ble.git_commit()

        self.assertRegex(commit, r"^[0-9a-f]{40}$|^unknown$")


if __name__ == "__main__":
    unittest.main()
