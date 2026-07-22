import base64
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent
TOOL = ROOT / "tools" / "verify_hist1_acceptance.py"
sys.path.insert(0, str(ROOT / "tools"))
from verify_hist1_acceptance import sleep_cadence_evidence  # noqa: E402
LAYOUT = "whoop4_0x2f_openstrap_v1_v24"
PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
PNG_IPHONE = bytearray(PNG_1X1)
PNG_IPHONE[16:20] = (1179).to_bytes(4, "big")
PNG_IPHONE[20:24] = (2556).to_bytes(4, "big")
PNG_IPHONE = bytes(PNG_IPHONE) + bytes(10_000)


class Hist1AcceptanceVerifierTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.pull = self.root / "pull"
        self.pre_pull = self.root / "pre-pull"
        self.pre_relaunch = self.root / "pre-relaunch"
        self.segments = self.pull / "historical-archive-segments"
        self.segments.mkdir(parents=True)
        self.pre_pull.mkdir(parents=True)
        (self.pre_relaunch / "atria-active-session.segments").mkdir(parents=True)
        self.start = datetime(2026, 7, 18, 1, 0, tzinfo=timezone.utc)
        self.reconnect = self.start + timedelta(hours=1)
        self.pull_time = self.reconnect + timedelta(minutes=2)
        self.screenshot = self.pull / "timeline.png"
        self.screenshot.write_bytes(PNG_IPHONE)
        self.recovery_log = self.pull / "recovery.log"

    def tearDown(self):
        self.scratch.cleanup()

    def write_evidence(self, *, missing_bucket: int | None = None,
                       omit_index_key: int | None = None,
                       duplicate_index_key: int | None = None,
                       historical_stride_seconds: int = 1) -> None:
        rows = []
        index_rows = [{"version": 1, "key": "pre-existing-key", "archivePath": "pre.jsonl"}]
        for second in range(0, 3600, historical_stride_seconds):
            if missing_bucket is not None and missing_bucket * 15 <= second < (missing_bucket + 1) * 15:
                continue
            timestamp = int(self.start.timestamp()) + second
            key = f"history-key-{second:04d}"
            rows.append({
                "schema": 3,
                "source": "0x2f",
                "layoutVersion": LAYOUT,
                "unix7": timestamp,
                "clockCorrectedUnix7": timestamp,
                "clockCorrectionStatus": "clock_ref_present",
                "gravityValidated": True,
                "whoofHR17": 61,
                "metricUsable": True,
                "currentSessionUsable": True,
                "_atriaHistoryKey": key,
            })
            if second != omit_index_key:
                index_rows.append({"version": 1, "key": key, "archivePath": "segment.jsonl"})
            if second == duplicate_index_key:
                index_rows.append({"version": 1, "key": key, "archivePath": "segment.jsonl"})
        (self.segments / "historical-archive-2026-07-18.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
        )
        (self.pull / "historical-archive.identity.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in index_rows), encoding="utf-8"
        )
        (self.pull / "pull-summary.txt").write_text(
            "\n".join([
                "process_status=running",
                "app_provenance_status=pass",
                f"app_provenance_sha256={'a' * 64}",
                f"app_binary_sha256={'b' * 64}",
                f"app_source_fingerprint={'c' * 64}",
                f"app_source_dirty_fingerprint={'d' * 64}",
                "official_whoop_process_status=not_listed",
                "offline_range_loss_backfill_pending=0",
                "offline_sync_last_status=gap_recovered",
                "offline_sync_last_reason=range_loss_terminal",
                f"historical_archive_metric_usable_rows={len(rows)}",
                "historical_archive_metric_ready=1",
                "historical_archive_metric_promotion_blocker=none",
                f"historical_archive_validated_metric_layouts={LAYOUT}",
                f"recovered_projection_evidence_revision={len(rows) + 1}",
                f"recovered_projection_evidence_fingerprint={'e' * 64}",
                "confirmed_sleep_records=1",
                "confirmed_workouts_count=1",
                "strain_projection_artifact_days=1",
                f"sleep_projection_artifact_revision={'1' * 64}",
                f"workout_projection_artifact_revision={'2' * 64}",
                f"strain_projection_artifact_revision={'3' * 64}",
                f"widget_projection_artifact_revision={'4' * 64}",
                "widget_projection_status=ok",
                f"widget_projection_created_at={(self.reconnect + timedelta(minutes=1)).isoformat()}",
                "widget_projection_app_group_enabled=1",
                "widget_projection_target_present=1",
            ]) + "\n",
            encoding="utf-8",
        )
        (self.pre_pull / "pull-summary.txt").write_text(
            "\n".join([
                "app_provenance_status=pass",
                f"app_provenance_sha256={'a' * 64}",
                f"app_binary_sha256={'b' * 64}",
                f"app_source_fingerprint={'c' * 64}",
                f"app_source_dirty_fingerprint={'d' * 64}",
                "recovered_projection_evidence_revision=1",
                f"recovered_projection_evidence_fingerprint={'f' * 64}",
                "confirmed_sleep_records=1",
                "confirmed_workouts_count=1",
                "strain_projection_artifact_days=1",
                f"sleep_projection_artifact_revision={'1' * 64}",
                f"workout_projection_artifact_revision={'2' * 64}",
                f"strain_projection_artifact_revision={'3' * 64}",
                f"widget_projection_artifact_revision={'5' * 64}",
                "widget_projection_status=ok",
                f"widget_projection_created_at={(self.start - timedelta(minutes=1)).isoformat()}",
                "widget_projection_app_group_enabled=1",
                "widget_projection_target_present=1",
                f"historical_archive_validated_metric_layouts={LAYOUT}",
            ]) + "\n",
            encoding="utf-8",
        )
        (self.pre_pull / "historical-archive.identity.jsonl").write_text(
            json.dumps({"version": 1, "key": "pre-existing-key", "archivePath": "pre.jsonl"}) + "\n",
            encoding="utf-8",
        )
        resident_samples = [
            {
                "t": self.start.timestamp() - 978_307_200 + second,
                "bpm": 61,
            }
            for second in range(3600)
        ]
        (self.pre_relaunch / "atria-active-session.segments" / "segment-000001.json").write_text(
            json.dumps({"samples": resident_samples}) + "\n",
            encoding="utf-8",
        )
        (self.pre_relaunch / "pull-summary.txt").write_text(
            "\n".join([
                "process_status=running",
                "app_provenance_status=pass",
                f"app_provenance_sha256={'a' * 64}",
                f"app_binary_sha256={'b' * 64}",
                "app_source_match_status=drift",
                "app_provenance_verification_mode=installed_only",
                "active_journal_final_status=ok",
            ]) + "\n",
            encoding="utf-8",
        )
        self.recovery_log.write_text(
            "ATRIADBG recovered_projection status=applied reason=test generation=7 archive=3600 live=0\n"
            "ATRIADBG recovered_derived status=published generation=7 archive_revision=3\n"
            "ATRIADBG widget_snapshot status=ok reason=recovered_fence_test_r3 schema=4\n",
            encoding="utf-8",
        )

    def run_verifier(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3", str(TOOL),
                "--pull-summary", str(self.pull / "pull-summary.txt"),
                "--pre-pull-summary", str(self.pre_pull / "pull-summary.txt"),
                "--pre-relaunch-pull-summary", str(self.pre_relaunch / "pull-summary.txt"),
                "--recovery-log", str(self.recovery_log),
                "--timeline-screenshot", str(self.screenshot),
                "--gap-start", self.start.isoformat(),
                "--reconnect", self.reconnect.isoformat(),
                "--pull-time", self.pull_time.isoformat(),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    def test_passes_only_from_rotated_exact_gap_rows_and_identity_index(self):
        self.write_evidence()
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("hist1_acceptance_status=pass", result.stdout)
        self.assertIn("archive_files_scanned=1", result.stdout)
        self.assertIn("timeline_points_derived=3600", result.stdout)
        self.assertIn("gap_buckets_expected=240", result.stdout)
        self.assertIn("gap_buckets_covered=240", result.stdout)
        self.assertIn("gap_coverage_percent=100.000", result.stdout)
        self.assertIn("historical_continuous_one_hz=1", result.stdout)
        self.assertIn("resident_continuous_one_hz=1", result.stdout)
        self.assertIn("gap_identity_keys_missing_or_nonunique=0", result.stdout)
        self.assertIn("analytics_recovered_projection_generation=7", result.stdout)
        self.assertIn("analytics_recovered_derived_archive_revision=3", result.stdout)
        self.assertIn("blockers=none", result.stdout)

    def test_fails_when_one_exact_fifteen_second_bucket_is_missing(self):
        self.write_evidence(missing_bucket=117)
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("gap_buckets_missing=1", result.stdout)
        self.assertIn("exact_gap_buckets_missing", result.stdout)

    def test_fails_sparse_fifteen_second_stream_even_when_every_bucket_is_occupied(self):
        self.write_evidence(historical_stride_seconds=15)
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("gap_buckets_missing=0", result.stdout)
        self.assertIn("historical_continuous_one_hz=0", result.stdout)
        self.assertIn("historical_recovery_not_continuous_one_hz", result.stdout)

    def test_timestamp_only_resident_rows_cannot_prove_overnight_survival(self):
        self.write_evidence()
        segment = self.pre_relaunch / "atria-active-session.segments" / "segment-000001.json"
        document = json.loads(segment.read_text(encoding="utf-8"))
        for sample in document["samples"]:
            sample.pop("bpm", None)
        segment.write_text(json.dumps(document) + "\n", encoding="utf-8")
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("resident_metric_points_in_gap=0", result.stdout)
        self.assertIn("resident_overnight_continuity_failed_before_relaunch", result.stdout)

    def test_torn_pre_relaunch_journal_cannot_be_accepted(self):
        self.write_evidence()
        summary = self.pre_relaunch / "pull-summary.txt"
        summary.write_text(
            summary.read_text(encoding="utf-8").replace(
                "active_journal_final_status=ok",
                "active_journal_final_status=torn_segment_sequence",
            ),
            encoding="utf-8",
        )
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("pre_relaunch_active_journal_not_lossless", result.stdout)

    def test_live_session_point_cannot_replace_missing_historical_recovery(self):
        self.write_evidence(missing_bucket=0)
        apple_start = self.start.timestamp() - 978_307_200
        (self.pull / "sessions.json").write_text(
            json.dumps([{"start": apple_start, "points": [{"t": 1, "bpm": 60}]}]) + "\n",
            encoding="utf-8",
        )
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("archive_metric_points_in_gap=3585", result.stdout)
        self.assertIn("live_metric_points_in_gap=1", result.stdout)
        self.assertIn("gap_buckets_covered=239", result.stdout)
        self.assertIn("historical_recovery_not_continuous_one_hz", result.stdout)

    def test_fails_when_gap_row_is_not_uniquely_present_in_durable_index(self):
        self.write_evidence(omit_index_key=33)
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("gap_identity_keys_missing_or_nonunique=1", result.stdout)
        self.assertIn("gap_rows_missing_unique_identity_index_entry", result.stdout)

        self.write_evidence(duplicate_index_key=44)
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("identity_index_duplicates=1", result.stdout)
        self.assertIn("history_identity_index_duplicates", result.stdout)

    def test_rejects_invalid_screenshot_and_removed_caller_point_override(self):
        self.write_evidence()
        self.screenshot.write_text("not a png", encoding="utf-8")
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid_timeline_screenshot", result.stdout)

        result = subprocess.run(
            [
                "python3", str(TOOL),
                "--pull-summary", str(self.pull / "pull-summary.txt"),
                "--pre-pull-summary", str(self.pre_pull / "pull-summary.txt"),
                "--pre-relaunch-pull-summary", str(self.pre_relaunch / "pull-summary.txt"),
                "--recovery-log", str(self.recovery_log),
                "--timeline-screenshot", str(self.screenshot),
                "--timeline-points", "999999",
                "--gap-start", self.start.isoformat(),
                "--reconnect", self.reconnect.isoformat(),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized arguments: --timeline-points", result.stderr)

    def test_rejects_stale_recovered_or_widget_publication_revision(self):
        self.write_evidence()
        self.recovery_log.write_text(
            "ATRIADBG recovered_projection status=applied reason=test generation=8 archive=240 live=0\n"
            "ATRIADBG recovered_derived status=published generation=7 archive_revision=3\n"
            "ATRIADBG widget_snapshot status=ok reason=recovered_fence_test_r2 schema=4\n",
            encoding="utf-8",
        )
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("recovered_derived_publication_stale_generation", result.stdout)
        self.assertIn("widget_publication_revision_stale_or_missing", result.stdout)

    def test_rejects_gap_rows_that_were_already_present_in_pre_gap_pull(self):
        self.write_evidence()
        pre_index = self.pre_pull / "historical-archive.identity.jsonl"
        with pre_index.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({
                "version": 1,
                "key": "history-key-0010",
                "archivePath": "pre.jsonl",
            }) + "\n")
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("preexisting_gap_identity_keys=1", result.stdout)
        self.assertIn("gap_rows_already_present_in_pre_gap_pull", result.stdout)

    def test_optional_analytics_may_be_absent_but_reported_counts_cannot_regress(self):
        self.write_evidence()
        pre_summary = self.pre_pull / "pull-summary.txt"
        pre_summary.write_text(
            pre_summary.read_text(encoding="utf-8")
            .replace("confirmed_sleep_records=1", "confirmed_sleep_records=0")
            .replace(f"sleep_projection_artifact_revision={'1' * 64}", "sleep_projection_artifact_revision=missing"),
            encoding="utf-8",
        )
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        post_summary = self.pull / "pull-summary.txt"
        post_summary.write_text(
            post_summary.read_text(encoding="utf-8").replace(
                "confirmed_workouts_count=1", "confirmed_workouts_count=0"
            ),
            encoding="utf-8",
        )
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("workout_projection_count_regressed", result.stdout)

    def test_gap_overlapping_workout_requires_a_new_workout_artifact_revision(self):
        self.write_evidence()
        post_summary = self.pull / "pull-summary.txt"
        with post_summary.open("a", encoding="utf-8") as handle:
            handle.write(f"latest_confirmed_workout_start={(self.start + timedelta(minutes=10)).isoformat()}\n")
            handle.write(f"latest_confirmed_workout_end={(self.start + timedelta(minutes=40)).isoformat()}\n")
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("workout_projection_artifact_revision_stale_for_gap_overlap", result.stdout)

        post_summary.write_text(
            post_summary.read_text(encoding="utf-8").replace(
                f"workout_projection_artifact_revision={'2' * 64}",
                f"workout_projection_artifact_revision={'6' * 64}",
            ),
            encoding="utf-8",
        )
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_sleep_cadence_requires_a_fresh_motion_backed_window(self):
        start = self.start
        end = start + timedelta(hours=6)
        stale = sleep_cadence_evidence({
            "latest_sleep_like_raw_start": (start - timedelta(days=2)).isoformat(),
            "latest_sleep_like_raw_end": (start - timedelta(days=2) + timedelta(hours=5)).isoformat(),
            "latest_sleep_like_raw_duration_s": "18000",
            "latest_sleep_like_raw_samples": "18000",
            "latest_sleep_like_raw_avg_hr": "61",
            "latest_sleep_like_raw_reason": "low_motion_low_hr",
        }, start, end)
        self.assertEqual(stale["status"], "missing")

        candidate = sleep_cadence_evidence({
            "latest_sleep_like_raw_start": (start + timedelta(hours=1)).isoformat(),
            "latest_sleep_like_raw_end": (start + timedelta(hours=5)).isoformat(),
            "latest_sleep_like_raw_duration_s": "14400",
            "latest_sleep_like_raw_samples": "14390",
            "latest_sleep_like_raw_avg_hr": "61",
            "latest_sleep_like_raw_reason": "low_motion_low_hr",
        }, start, end)
        self.assertEqual(candidate["status"], "candidate")
        self.assertTrue(candidate["motion_validated"])

        active = sleep_cadence_evidence({
            "latest_sleep_like_raw_start": (start + timedelta(hours=1)).isoformat(),
            "latest_sleep_like_raw_end": (start + timedelta(hours=5)).isoformat(),
            "latest_sleep_like_raw_duration_s": "14400",
            "latest_sleep_like_raw_samples": "14400",
            "latest_sleep_like_raw_avg_hr": "61",
            "latest_sleep_like_raw_reason": "motion_or_hr_active",
        }, start, end)
        self.assertEqual(active["status"], "missing")


if __name__ == "__main__":
    unittest.main()
