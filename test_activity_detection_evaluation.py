import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_step_archive_coverage import ROOT, encode_r10, write_archive


TOOL = ROOT / "tools" / "evaluate_activity_detection.py"


class ActivityDetectionEvaluationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.replay = Path(cls.build.name) / "replay_step_calibration"
        subprocess.run(
            [
                "swiftc",
                "-O",
                str(ROOT / "tools" / "replay_step_calibration.swift"),
                str(ROOT / "Atria" / "Atria" / "AtriaR10Motion.swift"),
                str(ROOT / "Atria" / "Atria" / "FrameParser.swift"),
                "-o",
                str(cls.replay),
            ],
            check=True,
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def make_archive(self, root: Path, gait_first: bool = True, missing_last: bool = False) -> Path:
        archive = root / "archive"
        rows = []
        total = 79 if missing_last else 80
        for offset in range(total):
            timestamp = 1_000 + offset
            gait = offset * 100 if (offset < 40 and gait_first) else None
            rows.append((timestamp * 1_000, encode_r10(timestamp, gait)))
        write_archive(archive / "capture.csv", rows)
        return archive

    @staticmethod
    def write_manifest(
        root: Path,
        second_activity: str = "rest",
        first_activity: str = "walk",
    ) -> Path:
        path = root / "manifest.json"
        path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "windows": [
                        {
                            "label": "Counted walk",
                            "activity": first_activity,
                            "start_ms": 1_000_000,
                            "end_ms": 1_040_000,
                        },
                        {
                            "label": "Confuser",
                            "activity": second_activity,
                            "start_ms": 1_040_000,
                            "end_ms": 1_080_000,
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )
        return path

    def run_tool(self, archive: Path, manifest: Path, output: Path | None = None):
        command = [
            "python3",
            str(TOOL),
            str(archive),
            str(manifest),
            "--replay-binary",
            str(self.replay),
        ]
        if output is not None:
            command += ["--output", str(output)]
        return subprocess.run(command, cwd=ROOT, capture_output=True, text=True)

    def test_real_replay_reports_clean_research_only_shadow_confusion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root)
            manifest = self.write_manifest(root)
            output = root / "report.json"
            result = self.run_tool(archive, manifest, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(report["validation_status"], "not_validated")
        self.assertEqual(report["research_only"], 1)
        self.assertEqual(report["activity_decoder_validated"], 0)
        self.assertEqual(report["production_promotions"], 0)
        self.assertEqual(report["production_label_changes"], 0)
        locomotion = report["confusion"]["locomotion_gate"]
        subtype = report["confusion"]["walking_subtype"]
        self.assertEqual(locomotion["true_positive_locomotion"], 1)
        self.assertEqual(locomotion["true_negative_confuser"], 1)
        self.assertEqual(locomotion["false_positive_confuser"], 0)
        self.assertTrue(locomotion["pass"])
        self.assertEqual(subtype["correct_walk_shadow"], 1)
        self.assertEqual(subtype["run_misidentified_as_walking_shadow"], 0)
        self.assertTrue(subtype["pass"])
        self.assertEqual(report["windows"][0]["shadow_candidate"], "walking_shadow")
        self.assertIsNone(report["windows"][1]["shadow_candidate"])

    def test_confuser_with_sustained_gait_is_reported_not_promoted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root, gait_first=False)
            # Replace the second half with gait while retaining a quiet first half.
            rows = []
            for offset in range(80):
                timestamp = 1_000 + offset
                gait = offset * 100 if offset >= 40 else None
                rows.append((timestamp * 1_000, encode_r10(timestamp, gait)))
            write_archive(archive / "capture.csv", rows)
            manifest = self.write_manifest(root, second_activity="dance")
            result = self.run_tool(archive, manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
        locomotion = report["confusion"]["locomotion_gate"]
        subtype = report["confusion"]["walking_subtype"]
        self.assertEqual(locomotion["false_positive_confuser"], 1)
        self.assertFalse(locomotion["pass"])
        self.assertEqual(subtype["confuser_misidentified_as_walking_shadow"], 1)
        self.assertFalse(subtype["pass"])
        self.assertEqual(report["activity_decoder_validated"], 0)
        self.assertEqual(report["production_promotions"], 0)

    def test_running_shadow_is_locomotion_evidence_but_wrong_walking_subtype(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root)
            manifest = self.write_manifest(root, first_activity="run")
            result = self.run_tool(archive, manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
        self.assertTrue(report["confusion"]["locomotion_gate"]["pass"])
        subtype = report["confusion"]["walking_subtype"]
        self.assertEqual(subtype["run_misidentified_as_walking_shadow"], 1)
        self.assertFalse(subtype["pass"])
        self.assertEqual(report["production_label_changes"], 0)

    def test_incomplete_raw_motion_fails_closed_without_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root, missing_last=True)
            manifest = self.write_manifest(root)
            output = root / "report.json"
            result = self.run_tool(archive, manifest, output)
            self.assertEqual(result.returncode, 2)
            self.assertIn("replay evidence is not scoreable", result.stderr)
            self.assertFalse(output.exists())
            failure = json.loads(result.stdout)
            self.assertEqual(failure["validation_status"], "not_validated")
            self.assertEqual(failure["research_only"], 1)
            self.assertEqual(failure["activity_decoder_validated"], 0)
            self.assertEqual(failure["production_promotions"], 0)

    def test_manifest_rejects_boolean_timestamps_overlap_and_unsupported_activity(self):
        cases = [
            (
                [
                    {"label": "Walk", "activity": "walk", "start_ms": True, "end_ms": 40_000},
                    {"label": "Rest", "activity": "rest", "start_ms": 40_000, "end_ms": 80_000},
                ],
                "must be an integer",
            ),
            (
                [
                    {"label": "Walk", "activity": "walk", "start_ms": 0, "end_ms": 40_000},
                    {"label": "Rest", "activity": "rest", "start_ms": 39_000, "end_ms": 80_000},
                ],
                "chronological and non-overlapping",
            ),
            (
                [
                    {"label": "Walk", "activity": "walk", "start_ms": 0, "end_ms": 40_000},
                    {"label": "Other", "activity": "teleporting", "start_ms": 40_000, "end_ms": 80_000},
                ],
                "unsupported activity",
            ),
        ]
        for windows, expected_error in cases:
            with self.subTest(expected_error=expected_error), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = self.make_archive(root)
                manifest = root / "manifest.json"
                manifest.write_text(json.dumps({"version": 1, "windows": windows}))
                result = self.run_tool(archive, manifest)
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected_error, result.stderr)

    def test_short_control_and_duplicate_json_keys_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root)
            short = root / "short.json"
            short.write_text(json.dumps({
                "version": 1,
                "windows": [
                    {"label": "Walk", "activity": "walk", "start_ms": 0, "end_ms": 40_000},
                    {"label": "Rest", "activity": "rest", "start_ms": 40_000, "end_ms": 45_000},
                ],
            }))
            short_result = self.run_tool(archive, short)
            self.assertEqual(short_result.returncode, 2)
            self.assertIn("at least 34 seconds", short_result.stderr)

            duplicate = root / "duplicate.json"
            duplicate.write_text(
                '{"version":1,"version":1,"windows":[]}',
                encoding="utf-8",
            )
            duplicate_result = self.run_tool(archive, duplicate)
            self.assertEqual(duplicate_result.returncode, 2)
            self.assertIn("duplicate JSON key", duplicate_result.stderr)

    def test_incompatible_replay_contract_and_timeout_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = self.make_archive(root)
            manifest = self.write_manifest(root)
            fake = root / "fake-replay"
            fake.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' 'expected_frames=40 missing_frames=0 coverage_pct=100.0 continuity_breaks=0 isolated_missing_seconds=0 long_breaks=0 longest_contiguous_seconds=40 evidence_scoreable=1'\n"
                "printf '%s\\n' 'gait_shadow_overlapping_windows=30 window_s=5 stride_s=1 accepted_overlapping_windows=30 accepted_ratio=1.0000 longest_accepted_stride_run_s=30 accepted_cadence_median_spm=120.00 accepted_periodicity_median=0.9000 accepted_consistency_median=0.9000 accepted_gyro_median=0.9000 activity_decoder_validated=0 production_label=none'\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            incompatible = subprocess.run(
                ["python3", str(TOOL), str(archive), str(manifest), "--replay-binary", str(fake)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(incompatible.returncode, 2)
            self.assertIn("gait window count does not match complete replay coverage", incompatible.stderr)

            fake.write_text("#!/bin/sh\nsleep 1\n", encoding="utf-8")
            fake.chmod(0o755)
            timed_out = subprocess.run(
                [
                    "python3", str(TOOL), str(archive), str(manifest),
                    "--replay-binary", str(fake), "--replay-timeout-seconds", "0.01",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(timed_out.returncode, 2)
            self.assertIn("replay timed out", timed_out.stderr)


if __name__ == "__main__":
    unittest.main()
