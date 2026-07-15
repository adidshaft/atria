#!/usr/bin/env python3
import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools import verify_physical_qualification as verifier
from tools import audit_handoff_status


BINARY_SHA = "a" * 64
SOURCE_COMMIT = "b" * 40
INSTALLED_APP = {
    "bundle_id": "com.adidshaft.atria",
    "binary_sha256": BINARY_SHA,
    "build": "Atria 1.0 (100)",
    "source_commit": SOURCE_COMMIT,
}


CHECKPOINT_ARTIFACTS = {
    "step_calibration": [
        ("calibration/manifest.json", "calibration_manifest"),
        ("calibration/fit.txt", "fit_output"),
    ],
    "step_holdout": [
        ("holdout/manifest.json", "holdout_manifest"),
        ("calibration/fit.txt", "fit_output"),
    ],
    "step_negatives": [("holdout/negative-replay.txt", "negative_replay")],
    "route_pause_gpx_share_relaunch": [
        ("route/route.json", "route"),
        ("route/workout.gpx", "gpx"),
        ("route/share.png", "screenshot"),
        ("route/events.jsonl", "event_log"),
    ],
    "zone_haptics": [("haptics/events.jsonl", "event_log")],
    "workout_background_recovery": [
        ("workout/events.jsonl", "event_log"),
        ("workout/pull-summary.txt", "pull_summary"),
    ],
    "live_activity": [
        ("live/lock-screen.png", "screenshot"),
        ("live/events.jsonl", "event_log"),
    ],
    "activity_crud": [
        ("activity/events.jsonl", "event_log"),
        ("activity/pull-summary.txt", "pull_summary"),
    ],
    "journal_deep_link": [
        ("journal/opened.png", "screenshot"),
        ("journal/events.jsonl", "event_log"),
    ],
    "sleep_save": [
        ("sleep/events.jsonl", "event_log"),
        ("sleep/pull-summary.txt", "pull_summary"),
    ],
    "battery_charging_reconnect": [
        ("battery/pull-summary.txt", "pull_summary"),
        ("battery/charging.png", "screenshot"),
        ("battery/events.jsonl", "event_log"),
    ],
    "responsiveness": [
        ("performance/session.mov", "screen_recording"),
        ("performance/trace.xml", "performance_trace"),
    ],
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_passing_report(root: Path) -> tuple[Path, dict]:
    artifacts: list[dict] = []
    artifact_by_path: dict[str, dict] = {}

    identity_path = "identity/installed-app.json"
    identity_data = (json.dumps(INSTALLED_APP, sort_keys=True) + "\n").encode()
    target = root / identity_path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(identity_data)
    identity_artifact = {
        "path": identity_path,
        "sha256": sha256(identity_data),
        "kind": "app_identity",
        "app_binary_sha256": BINARY_SHA,
    }
    artifacts.append(identity_artifact)
    artifact_by_path[identity_path] = identity_artifact

    for entries in CHECKPOINT_ARTIFACTS.values():
        for relative, kind in entries:
            if relative in artifact_by_path:
                continue
            payload = f"Atria physical evidence: {relative}\n".encode()
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            artifact = {
                "path": relative,
                "sha256": sha256(payload),
                "kind": kind,
                "app_binary_sha256": BINARY_SHA,
            }
            artifacts.append(artifact)
            artifact_by_path[relative] = artifact

    checkpoints = []
    for checkpoint_id, contract in verifier.REQUIRED_CHECKPOINTS.items():
        checkpoints.append({
            "id": checkpoint_id,
            "status": "pass",
            "observed_at": "2026-07-15T11:00:00Z",
            "artifact_paths": [path for path, _ in CHECKPOINT_ARTIFACTS[checkpoint_id]],
            "observations": sorted(contract["observations"]),
            "command_pulses": verifier.HAPTIC_ORDER if checkpoint_id == "zone_haptics" else [],
            "witnessed_pulses": verifier.HAPTIC_ORDER if checkpoint_id == "zone_haptics" else [],
        })

    report = {
        "schema_version": 1,
        "qualification_id": "atria-physical-20260715",
        "created_at": "2026-07-15T12:00:00Z",
        "installed_app": dict(INSTALLED_APP),
        "artifacts": artifacts,
        "checkpoints": checkpoints,
    }
    report_path = root / "docs/evidence/physical-qualification/summary.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report_path, report


def rewrite(path: Path, report: dict) -> None:
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class PhysicalQualificationTests(unittest.TestCase):
    def test_complete_build_bound_report_passes_library_and_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path, _ = write_passing_report(root)
            result = verifier.verify_report(root, report_path, expected_binary_sha256=BINARY_SHA)
            cli = subprocess.run(
                [
                    "python3",
                    str(Path(__file__).parent / "tools/verify_physical_qualification.py"),
                    str(report_path),
                    "--repo",
                    str(root),
                    "--expected-binary-sha256",
                    BINARY_SHA,
                ],
                capture_output=True,
                text=True,
            )

        self.assertEqual(result["status"], "pass", result)
        self.assertEqual(result["checkpoint_count"], len(verifier.REQUIRED_CHECKPOINTS))
        self.assertEqual(cli.returncode, 0, cli.stdout + cli.stderr)
        self.assertIn("status=pass", cli.stdout)

    def test_missing_failed_unknown_and_duplicate_checkpoints_fail_closed(self):
        mutations = {
            "missing": lambda report: report["checkpoints"].pop(),
            "failed": lambda report: report["checkpoints"][0].update(status="fail"),
            "unknown": lambda report: report["checkpoints"][0].update(id="not_a_gate"),
            "duplicate": lambda report: report["checkpoints"].append(copy.deepcopy(report["checkpoints"][0])),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                report_path, report = write_passing_report(root)
                mutate(report)
                rewrite(report_path, report)
                result = verifier.verify_report(root, report_path)
                self.assertEqual(result["status"], "fail", result)

    def test_boolean_as_integer_unknown_fields_and_bad_haptic_witness_fail(self):
        mutations = {
            "boolean_schema": lambda report: report.update(schema_version=True),
            "unknown_report_field": lambda report: report.update(unreviewed=True),
            "boolean_pulse": lambda report: next(
                row for row in report["checkpoints"] if row["id"] == "zone_haptics"
            ).update(command_pulses=[1, 3, True, 1]),
            "wrong_witness": lambda report: next(
                row for row in report["checkpoints"] if row["id"] == "zone_haptics"
            ).update(witnessed_pulses=[1, 3, 1, 1]),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                report_path, report = write_passing_report(root)
                mutate(report)
                rewrite(report_path, report)
                result = verifier.verify_report(root, report_path)
                self.assertEqual(result["status"], "fail", result)

    def test_duplicate_json_keys_fail_before_schema_interpretation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path, _ = write_passing_report(root)
            text = report_path.read_text(encoding="utf-8")
            report_path.write_text(
                text.replace("{", '{\n  "schema_version": 1,', 1),
                encoding="utf-8",
            )
            result = verifier.verify_report(root, report_path)

        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["blockers"], ["duplicate_physical_qualification_json_key"])

    def test_unhashed_missing_tampered_duplicate_and_mismatched_build_artifacts_fail(self):
        def unhashed(report: dict) -> None:
            report["checkpoints"][0]["artifact_paths"].append("not-listed.bin")

        def missing(root: Path, report: dict) -> None:
            (root / report["artifacts"][1]["path"]).unlink()

        def tampered(root: Path, report: dict) -> None:
            (root / report["artifacts"][1]["path"]).write_text("tampered", encoding="utf-8")

        def duplicate_path(report: dict) -> None:
            report["artifacts"].append(copy.deepcopy(report["artifacts"][1]))

        def duplicate_digest(report: dict) -> None:
            report["artifacts"][2]["sha256"] = report["artifacts"][1]["sha256"]

        def mismatched_build(report: dict) -> None:
            report["artifacts"][1]["app_binary_sha256"] = "c" * 64

        cases = [
            ("unhashed", None, unhashed),
            ("missing", missing, None),
            ("tampered", tampered, None),
            ("duplicate_path", None, duplicate_path),
            ("duplicate_digest", None, duplicate_digest),
            ("mismatched_build", None, mismatched_build),
        ]
        for name, file_mutation, report_mutation in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                report_path, report = write_passing_report(root)
                if file_mutation:
                    file_mutation(root, report)
                if report_mutation:
                    report_mutation(report)
                rewrite(report_path, report)
                result = verifier.verify_report(root, report_path)
                self.assertEqual(result["status"], "fail", result)

    def test_composite_checkpoint_requires_exact_observations_and_artifact_kinds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path, report = write_passing_report(root)
            route = next(row for row in report["checkpoints"] if row["id"] == "route_pause_gpx_share_relaunch")
            route["observations"].remove("post_save_share")
            route["artifact_paths"] = [
                path for path in route["artifact_paths"]
                if not path.endswith("workout.gpx")
            ]
            rewrite(report_path, report)
            result = verifier.verify_report(root, report_path)

        self.assertEqual(result["status"], "fail")
        self.assertIn("checkpoint_route_pause_gpx_share_relaunch_observations_mismatch", result["blockers"])
        self.assertIn("checkpoint_route_pause_gpx_share_relaunch_missing_gpx", result["blockers"])

    def test_identity_file_and_expected_binary_must_match_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path, _ = write_passing_report(root)
            result = verifier.verify_report(root, report_path, expected_binary_sha256="c" * 64)

        self.assertEqual(result["status"], "fail")
        self.assertIn("installed_app_binary_mismatch", result["blockers"])

    def test_handoff_audit_requires_report_even_when_other_physical_gates_are_deferred(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in audit_handoff_status.LOCAL_CHECK_FILES + audit_handoff_status.REQUIRED_SOURCE_FILES:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture", encoding="utf-8")
            missing = audit_handoff_status.evaluate(
                root,
                skip_external_reference=True,
                defer_physical_long_wear=True,
                defer_accessibility_performance=True,
            )
            report_path, _ = write_passing_report(root)
            passing = audit_handoff_status.evaluate(
                root,
                skip_external_reference=True,
                defer_physical_long_wear=True,
                defer_accessibility_performance=True,
                physical_qualification_path=report_path,
            )

        self.assertEqual(missing["status"], "not_complete")
        self.assertIn("physical_qualification_proof", missing["blockers"])
        self.assertEqual(passing["status"], "complete", passing)
        self.assertEqual(passing["physical_qualification"]["status"], "pass")


if __name__ == "__main__":
    unittest.main()
