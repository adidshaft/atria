#!/usr/bin/env python3
import argparse
import json
import hashlib
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
        self.assertEqual(final["active_duration_series_s"], [60.0, 120.0])
        self.assertEqual(final["active_hr_series"], [60.0, 120.0])
        self.assertEqual(final["active_rr_series"], [55.0, 110.0])
        self.assertEqual(final["battery_series"], [80.0, 76.0])
        self.assertTrue(final["active_duration_nondecreasing"])
        self.assertTrue(final["active_hr_nondecreasing"])
        self.assertTrue(final["active_rr_nondecreasing"])
        self.assertEqual(final["battery_drop_from_first_percent"], -4.0)

    def test_trend_summary_flags_stalled_active_collection(self):
        trends = monitor_long_wear.trend_summary([
            {
                "active_journal": {
                    "duration_s": 120.0,
                    "delta_samples": 120,
                    "delta_rr": 110,
                    "battery": 80,
                },
            },
            {
                "active_journal": {
                    "duration_s": 120.0,
                    "delta_samples": 100,
                    "delta_rr": 108,
                    "battery": 79,
                },
            },
        ])

        self.assertTrue(trends["active_duration_nondecreasing"])
        self.assertFalse(trends["active_hr_nondecreasing"])
        self.assertFalse(trends["active_rr_nondecreasing"])
        self.assertEqual(trends["battery_drop_from_first_percent"], -1.0)

    def test_acceptance_passes_with_overnight_quality_evidence(self):
        final = {
            "samples": 9,
            "latest_attributed_session_status": "ok",
            "latest_attributed_active_status": "ok",
            "latest_attributed_durable_union_status": "ok",
            "attributed_active_ok_samples": 9,
            "latest_attributed_session_observation_span_s": 9 * 60 * 60,
            "latest_attributed_session_coverage_percent": 91.0,
            "max_attributed_active_accepted_gap_s": 0.0,
            "max_attributed_session_accepted_gap_s": 2.0,
            "latest_attributed_durable_union_observation_span_s": 9 * 60 * 60,
            "latest_attributed_durable_union_coverage_percent": 91.0,
            "max_attributed_durable_union_accepted_gap_s": 2.0,
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
            "latest_attributed_session_status": "ok",
            "latest_attributed_active_status": "ok",
            "latest_attributed_durable_union_status": "ok",
            "attributed_active_ok_samples": 1,
            "latest_attributed_session_observation_span_s": 2731.1,
            "latest_attributed_session_coverage_percent": 50.0,
            "max_attributed_active_accepted_gap_s": 0.0,
            "max_attributed_session_accepted_gap_s": 0.0,
            "latest_attributed_durable_union_observation_span_s": 2731.1,
            "latest_attributed_durable_union_coverage_percent": 50.0,
            "max_attributed_durable_union_accepted_gap_s": 0.0,
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

    def test_attributed_timeline_keeps_boundary_silence_in_gap_and_coverage(self):
        projected = monitor_long_wear.attributed_timeline(
            [110.0, 120.0, 120.0, 130.0],
            window_start=100.0,
            window_end=160.0,
            max_gap=15.0,
            source_files=2,
        )

        self.assertEqual(projected["status"], "ok")
        self.assertEqual(projected["samples"], 3)
        self.assertEqual(projected["boundary_start_gap_s"], 10.0)
        self.assertEqual(projected["boundary_end_gap_s"], 30.0)
        self.assertEqual(projected["max_accepted_gap_s"], 30.0)
        self.assertAlmostEqual(projected["coverage_percent"], 50.0)

    def test_acceptance_fails_closed_without_run_attributed_evidence(self):
        result = monitor_long_wear.evaluate_acceptance({
            "samples": 9,
            "thermal_states": ["nominal"],
            "battery_delta": 0,
        }, args(preset="overnight"))

        self.assertEqual(result["acceptance_status"], "fail")
        self.assertIn("attributed_evidence", result["acceptance_blockers"])
        self.assertIn("active_ok_samples", result["acceptance_blockers"])

    def test_projection_clips_pre_run_points_and_ignores_legacy_cumulative_gap(self):
        with tempfile.TemporaryDirectory() as tmp:
            pull = Path(tmp)
            start_unix = monitor_long_wear.parsed_utc_timestamp("2026-07-14T17:17:18Z")
            start_apple = monitor_long_wear.apple_reference_seconds(start_unix)
            (pull / "sessions.json").write_text(json.dumps([{
                "start": start_apple - 60,
                "hrMaxAcceptedGap": 360.0,
                "points": [{"t": 0, "bpm": 70}, {"t": 60, "bpm": 71},
                           {"t": 78, "bpm": 72}, {"t": 96, "bpm": 73}],
            }]), encoding="utf-8")
            segment_dir = pull / "atria-active-session.segments"
            segment_dir.mkdir()
            (segment_dir / "segment-1.json").write_text(json.dumps({
                "maxAcceptedHRGap": 360.0,
                "samples": [{"t": start_apple}, {"t": start_apple + 18}],
            }), encoding="utf-8")

            result = monitor_long_wear.project_run_attributed_evidence(
                pull, "2026-07-14T17:17:18Z", "2026-07-14T17:17:54Z", 30.0)

        self.assertEqual(result["run_attributed_sessions"]["samples"], 3)
        self.assertEqual(result["run_attributed_sessions"]["max_accepted_gap_s"], 18.0)
        self.assertEqual(result["run_attributed_active_journal"]["max_accepted_gap_s"], 18.0)

    def test_projection_handles_midnight_dedupes_and_counts_invalid_timestamps(self):
        start = monitor_long_wear.apple_reference_seconds(
            monitor_long_wear.parsed_utc_timestamp("2026-07-14T23:59:50Z"))
        with tempfile.TemporaryDirectory() as tmp:
            pull = Path(tmp)
            (pull / "sessions.json").write_text(json.dumps([
                {"start": start, "points": [{"t": 0}, {"t": 10}, {"t": 20}, {"t": "bad"}]},
                {"start": start, "points": [{"t": 10}, {"t": 20}, {"t": 50}]},
            ]), encoding="utf-8")

            result = monitor_long_wear.project_run_attributed_evidence(
                pull, "2026-07-14T23:59:50Z", "2026-07-15T00:00:20Z", 30.0)

        sessions = result["run_attributed_sessions"]
        self.assertEqual(sessions["samples"], 3)
        self.assertEqual(sessions["malformed_timestamps"], 1)
        self.assertEqual(sessions["future_timestamps"], 1)
        self.assertEqual(sessions["coverage_percent"], 100.0)
        self.assertLessEqual(sessions["coverage_percent"], 100.0)

    def test_cumulative_projection_survives_rotated_checkpoint_segments(self):
        start = monitor_long_wear.apple_reference_seconds(
            monitor_long_wear.parsed_utc_timestamp("2026-07-14T17:00:00Z"))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "pull-1" / "atria-active-session.segments"
            second = root / "pull-2" / "atria-active-session.segments"
            first.mkdir(parents=True)
            second.mkdir(parents=True)
            (first / "segment-early.json").write_text(json.dumps({"samples": [
                {"t": start}, {"t": start + 10}, {"t": start + 20},
                {"t": "bad"}, {"t": start + 999},
            ]}), encoding="utf-8")
            # Rotation removes the early segment from checkpoint two. One
            # timestamp overlaps and must not inflate samples or coverage.
            (second / "segment-late.json").write_text(json.dumps({"samples": [
                {"t": start + 20}, {"t": start + 30}, {"t": start + 40},
            ]}), encoding="utf-8")
            cumulative = {}

            early = monitor_long_wear.project_run_attributed_evidence(
                root / "pull-1", "2026-07-14T17:00:00Z",
                "2026-07-14T17:00:20Z", 15, cumulative=cumulative)
            late = monitor_long_wear.project_run_attributed_evidence(
                root / "pull-2", "2026-07-14T17:00:00Z",
                "2026-07-14T17:00:40Z", 15, cumulative=cumulative)

        self.assertEqual(early["run_attributed_active_journal"]["samples"], 3)
        projected = late["run_attributed_active_journal"]
        self.assertEqual(projected["samples"], 5)
        self.assertEqual(projected["boundary_start_gap_s"], 0)
        self.assertEqual(projected["boundary_end_gap_s"], 0)
        self.assertEqual(projected["max_accepted_gap_s"], 10)
        self.assertEqual(projected["coverage_percent"], 100)
        self.assertEqual(projected["malformed_timestamps"], 1)
        self.assertEqual(projected["future_timestamps"], 1)
        self.assertEqual(projected["source_files"], 2)

    def test_cumulative_diagnostics_deduplicate_repeated_full_snapshot_artifacts(self):
        start = monitor_long_wear.apple_reference_seconds(
            monitor_long_wear.parsed_utc_timestamp("2026-07-14T17:00:00Z"))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cumulative = {}
            results = []
            for pull_name, captured in (("pull-1", "2026-07-14T17:00:20Z"),
                                        ("pull-2", "2026-07-14T17:00:30Z")):
                segment_dir = root / pull_name / "atria-active-session.segments"
                segment_dir.mkdir(parents=True)
                (segment_dir / "segment-00000007.json").write_text(json.dumps({
                    "id": "stable-journal", "sequence": 7,
                    "samples": [{"t": start}, {"t": "bad"}, {"t": start + 999}],
                }), encoding="utf-8")
                results.append(monitor_long_wear.project_run_attributed_evidence(
                    root / pull_name, "2026-07-14T17:00:00Z", captured, 30,
                    cumulative=cumulative)["run_attributed_active_journal"])

        self.assertEqual(results[-1]["source_files"], 1)
        self.assertEqual(results[-1]["malformed_timestamps"], 1)
        self.assertEqual(results[-1]["future_timestamps"], 1)

    def test_recent_gap_window_ages_out_old_gap_but_whole_run_remains_blocked(self):
        start = monitor_long_wear.apple_reference_seconds(
            monitor_long_wear.parsed_utc_timestamp("2026-07-14T17:00:00Z"))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first_segments = root / "pull-1" / "atria-active-session.segments"
            first_segments.mkdir(parents=True)
            (first_segments / "segment-old.json").write_text(json.dumps({
                "id": "old", "sequence": 0,
                "samples": [{"t": start}, {"t": start + 10}, {"t": start + 100}],
            }), encoding="utf-8")
            cumulative = {}
            early = monitor_long_wear.project_run_attributed_evidence(
                root / "pull-1", "2026-07-14T17:00:00Z",
                "2026-07-14T17:01:40Z", 30, cumulative=cumulative)

            later_segments = root / "pull-2" / "atria-active-session.segments"
            later_segments.mkdir(parents=True)
            (later_segments / "segment-clean.json").write_text(json.dumps({
                "id": "clean", "sequence": 0,
                "samples": [{"t": start + offset} for offset in range(200, 3801, 10)],
            }), encoding="utf-8")
            late = monitor_long_wear.project_run_attributed_evidence(
                root / "pull-2", "2026-07-14T17:00:00Z",
                "2026-07-14T18:03:20Z", 30, cumulative=cumulative)

        self.assertEqual(early["run_attributed_durable_union"]["max_accepted_gap_s"], 90)
        self.assertEqual(late["run_attributed_durable_union"]["max_accepted_gap_s"], 100)
        recent = late["run_attributed_durable_union_recent"]
        self.assertEqual(recent["observation_span_s"], monitor_long_wear.RECENT_ATTRIBUTED_WINDOW_SECONDS)
        self.assertEqual(recent["max_accepted_gap_s"], 10)

        final = monitor_long_wear.rollup([
            {**early, "active_journal": {"status": "ok", "thermal": "nominal", "battery": 80}},
            {**late, "active_journal": {"status": "ok", "thermal": "nominal", "battery": 79}},
        ])
        result = monitor_long_wear.evaluate_acceptance(final, args(min_samples=2, min_span=0,
                                                                   min_coverage=0, max_gap=30))
        self.assertIn("active_gap", result["acceptance_blockers"])
        self.assertNotIn("recent_gap", result["acceptance_blockers"])
        self.assertEqual(result["acceptance_diagnostics"]["active_gap"]["observed_s"], 100)
        self.assertEqual(result["acceptance_diagnostics"]["recent_gap"]["observed_s"], 10)
        self.assertEqual(result["acceptance_diagnostics"]["recent_gap"]["configured_window_s"], 3600)
        self.assertIn("recent_diagnostic_only", result["acceptance_diagnostics"]["recent_gap"]["scope"])

    def test_durable_union_bridges_normal_active_segment_settlement(self):
        start = monitor_long_wear.apple_reference_seconds(
            monitor_long_wear.parsed_utc_timestamp("2026-07-14T17:00:00Z"))
        with tempfile.TemporaryDirectory() as tmp:
            pull = Path(tmp)
            segment_dir = pull / "atria-active-session.segments"
            segment_dir.mkdir()
            (segment_dir / "segment-1.json").write_text(json.dumps({"samples": [
                {"t": start}, {"t": start + 10}, {"t": start + 40},
            ]}), encoding="utf-8")
            (pull / "sessions.json").write_text(json.dumps([{
                "start": start, "points": [{"t": 20}, {"t": 30}],
            }]), encoding="utf-8")

            result = monitor_long_wear.project_run_attributed_evidence(
                pull, "2026-07-14T17:00:00Z", "2026-07-14T17:00:40Z", 15)

        self.assertEqual(result["run_attributed_active_journal"]["max_accepted_gap_s"], 30)
        union = result["run_attributed_durable_union"]
        self.assertEqual(union["samples"], 5)
        self.assertEqual(union["max_accepted_gap_s"], 10)
        self.assertEqual(union["coverage_percent"], 100)

    def test_durable_union_keeps_hole_missing_from_both_layers(self):
        start = monitor_long_wear.apple_reference_seconds(
            monitor_long_wear.parsed_utc_timestamp("2026-07-14T17:00:00Z"))
        with tempfile.TemporaryDirectory() as tmp:
            pull = Path(tmp)
            segment_dir = pull / "atria-active-session.segments"
            segment_dir.mkdir()
            (segment_dir / "segment-1.json").write_text(json.dumps({"samples": [
                {"t": start}, {"t": start + 10}, {"t": start + 50},
            ]}), encoding="utf-8")
            (pull / "sessions.json").write_text(json.dumps([{
                "start": start, "points": [{"t": 0}, {"t": 10}, {"t": 50}],
            }]), encoding="utf-8")

            result = monitor_long_wear.project_run_attributed_evidence(
                pull, "2026-07-14T17:00:00Z", "2026-07-14T17:00:50Z", 15)

        union = result["run_attributed_durable_union"]
        self.assertEqual(union["max_accepted_gap_s"], 40)
        self.assertEqual(union["coverage_percent"], 20)

    def test_acceptance_uses_attributed_thresholds_not_legacy_diagnostics(self):
        final = {
            "samples": 2, "latest_attributed_session_status": "ok",
            "latest_attributed_active_status": "ok", "attributed_active_ok_samples": 2,
            "latest_attributed_durable_union_status": "ok",
            "latest_attributed_session_observation_span_s": 28800.0,
            "latest_attributed_session_coverage_percent": 85.0,
            "max_attributed_active_accepted_gap_s": 30.0,
            "max_attributed_session_accepted_gap_s": 30.0,
            "latest_attributed_durable_union_observation_span_s": 28800.0,
            "latest_attributed_durable_union_coverage_percent": 85.0,
            "max_attributed_durable_union_accepted_gap_s": 30.0,
            "latest_recent_session_coverage_percent": 0.0,
            "max_recent_accepted_gap_s": 360.0,
            "max_active_accepted_gap_s": 360.0,
            "thermal_states": ["nominal"], "battery_delta": 0,
        }
        self.assertEqual(monitor_long_wear.evaluate_acceptance(final, args())["acceptance_status"], "pass")
        final["max_attributed_durable_union_accepted_gap_s"] = 30.001
        self.assertIn("recent_gap", monitor_long_wear.evaluate_acceptance(final, args())["acceptance_blockers"])

    def test_recompute_preserves_pulled_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            run = repo / "run"
            pull = run / "pull-0000"
            segment_dir = pull / "atria-active-session.segments"
            segment_dir.mkdir(parents=True)
            start = monitor_long_wear.apple_reference_seconds(
                monitor_long_wear.parsed_utc_timestamp("2026-07-14T17:00:00Z"))
            session_path = pull / "sessions.json"
            segment_path = segment_dir / "segment-1.json"
            session_path.write_text(json.dumps([{"start": start, "points": [{"t": 0}, {"t": 10}]}]), encoding="utf-8")
            segment_path.write_text(json.dumps({"samples": [{"t": start}, {"t": start + 10}]}), encoding="utf-8")
            before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in (session_path, segment_path)}
            (run / "run.json").write_text(json.dumps({
                "monitor_started_at": "2026-07-14T17:00:00Z", "label": "test",
                "preset": "custom", "planned_samples": 1, "planned_interval_s": 10,
                "app_commit": "app", "monitor_commit": "old",
                "criteria": {"min_samples": 1, "min_span_s": 10, "min_coverage_percent": 100,
                             "max_gap_s": 30, "allowed_thermal": ["nominal"],
                             "max_battery_drop_percent": 35},
            }), encoding="utf-8")
            source_samples = run / "samples.jsonl"
            source_samples.write_text(json.dumps({
                "sample": 0,
                "captured_at": "2026-07-14T17:00:10Z", "pull_dir": str(pull),
                "status": "ok", "active_journal": {"status": "ok", "thermal": "nominal", "battery": 80},
            }) + "\n", encoding="utf-8")
            source_hash = hashlib.sha256(source_samples.read_bytes()).hexdigest()
            namespace = args(label="unused")

            code = monitor_long_wear.recompute_existing_run(repo, run, namespace)

            self.assertEqual(code, 0)
            self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in before})
            self.assertEqual(hashlib.sha256(source_samples.read_bytes()).hexdigest(), source_hash)
            recomputed = run / "recomputed-samples.jsonl"
            self.assertIn("run_attributed_sessions", json.loads(recomputed.read_text()))
            self.assertTrue((run / "summary.json").is_file())

    def test_recompute_selects_primary_planned_sequence_after_later_reset(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            run = repo / "run"
            run.mkdir()
            first_stamp = "20260714T171718Z"
            first_unix = monitor_long_wear.parsed_utc_timestamp(first_stamp)
            records = []
            for sample_index in range(11):
                stamp_unix = first_unix + sample_index * 3600
                stamp = monitor_long_wear.datetime.fromtimestamp(
                    stamp_unix, tz=monitor_long_wear.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
                pull = run / f"pull-{sample_index:04d}-{stamp}"
                segments = pull / "atria-active-session.segments"
                segments.mkdir(parents=True)
                apple_stamp = monitor_long_wear.apple_reference_seconds(stamp_unix)
                (pull / "sessions.json").write_text(json.dumps([{
                    "start": apple_stamp, "points": [{"t": 0}],
                }]), encoding="utf-8")
                (segments / f"segment-{sample_index}.json").write_text(json.dumps({
                    "id": f"primary-{sample_index}", "sequence": sample_index,
                    "samples": [{"t": apple_stamp}],
                }), encoding="utf-8")
                records.append({
                    "sample": sample_index, "captured_at": stamp, "pull_dir": str(pull),
                    "returncode": 0,
                    "active_journal": {
                        "status": "ok", "thermal": "serious" if sample_index == 0 else "nominal",
                        "battery": 75 - sample_index,
                    },
                })

            reset_stamp = "20260715T032011Z"
            reset = run / f"pull-0000-{reset_stamp}"
            reset_segments = reset / "atria-active-session.segments"
            reset_segments.mkdir(parents=True)
            reset_unix = monitor_long_wear.parsed_utc_timestamp(reset_stamp)
            reset_apple = monitor_long_wear.apple_reference_seconds(reset_unix)
            (reset / "sessions.json").write_text(json.dumps([{
                "start": reset_apple, "points": [{"t": 0}],
            }]), encoding="utf-8")
            (reset_segments / "segment-reset.json").write_text(json.dumps({
                "id": "accidental", "sequence": 0, "samples": [{"t": reset_apple}],
            }), encoding="utf-8")
            records.append({
                "sample": 0, "captured_at": reset_stamp, "pull_dir": str(reset),
                "returncode": 0,
                "active_journal": {"status": "ok", "thermal": "nominal", "battery": 99},
            })
            source_samples = run / "samples.jsonl"
            source_samples.write_text(
                "".join(json.dumps(item) + "\n" for item in records), encoding="utf-8")
            source_hash = hashlib.sha256(source_samples.read_bytes()).hexdigest()
            (run / "run.json").write_text(json.dumps({
                "monitor_started_at": "2026-07-15T03:20:11.446083Z",
                "label": "overnight", "preset": "overnight", "planned_samples": 11,
                "planned_interval_s": 3600, "app_commit": "installed", "monitor_commit": "old",
                "criteria": {
                    "min_samples": 9, "min_span_s": 28800, "min_coverage_percent": 85,
                    "max_gap_s": 30, "allowed_thermal": ["nominal", "fair"],
                    "max_battery_drop_percent": 35,
                },
            }), encoding="utf-8")

            code = monitor_long_wear.recompute_existing_run(repo, run, args(label="unused"))

            self.assertEqual(code, 0)
            self.assertEqual(hashlib.sha256(source_samples.read_bytes()).hexdigest(), source_hash)
            summary = json.loads((run / "summary.json").read_text())
            self.assertEqual(summary["samples"], 11)
            self.assertEqual(summary["thermal_states"], ["nominal", "serious"])
            self.assertEqual(summary["battery_latest"], 65)
            self.assertEqual(summary["observation_started_at"], first_stamp)
            self.assertEqual(summary["observation_finished_at"], "20260715T031718Z")
            self.assertEqual(summary["observation_span_s"], 36000)
            self.assertEqual(summary["observation_started_at_source"],
                             "primary_first_capture_metadata_after_primary_sequence")
            selection = summary["sample_selection"]
            self.assertEqual(selection["selected_sample_indices"], list(range(11)))
            self.assertEqual(selection["excluded_sample_records"], 1)
            self.assertEqual(selection["excluded_records"][0]["source_line"], 12)
            self.assertEqual(selection["excluded_records"][0]["reason"], "later_sequence_reset")
            self.assertEqual(len((run / "recomputed-samples.jsonl").read_text().splitlines()), 11)
            self.assertIn("active_gap", summary["acceptance_blockers"])
            self.assertIn("thermal", summary["acceptance_blockers"])

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

    def test_prepare_fresh_run_directory_refuses_existing_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fresh = root / "fresh"
            monitor_long_wear.prepare_fresh_run_directory(fresh)
            self.assertTrue(fresh.is_dir())

            existing = root / "existing"
            existing.mkdir()
            source = existing / "samples.jsonl"
            source.write_text('{"sample": 0}\n', encoding="utf-8")
            before = source.read_bytes()

            with self.assertRaisesRegex(FileExistsError, "not empty"):
                monitor_long_wear.prepare_fresh_run_directory(existing)

            self.assertEqual(source.read_bytes(), before)

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
        self.assertNotIn("&& exec", shell)
        self.assertIn(
            "trap 'launchctl remove com.adidshaft.atria.longwear.overnight-handoff-21",
            shell,
        )


if __name__ == "__main__":
    unittest.main()
