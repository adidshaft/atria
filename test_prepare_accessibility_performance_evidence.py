#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools import prepare_accessibility_performance_evidence


class PrepareAccessibilityPerformanceEvidenceTests(unittest.TestCase):
    def test_default_manifest_is_a_non_passing_measured_draft(self):
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

            manifest = prepare_accessibility_performance_evidence.default_manifest(
                repo,
                "2026-06-22T12:00:00Z",
            )

        self.assertEqual(manifest["device"], "iPhone 15 Pro")
        self.assertEqual(manifest["measured_at"], "2026-06-22T12:00:00Z")
        self.assertEqual(manifest["app_commit"], expected_commit)
        self.assertEqual(manifest["dashboard_scroll_fps"], 0)
        self.assertTrue(manifest["instruments_trace"])
        self.assertTrue(all(value is False for value in manifest["accessibility_checks"].values()))

    def test_build_string_falls_back_to_xcode_project_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "Atria" / "Atria.xcodeproj").mkdir(parents=True)
            (repo / "Atria" / "Info.plist").write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Atria</string>
</dict>
</plist>
""",
                encoding="utf-8",
            )
            (repo / "Atria" / "Atria.xcodeproj" / "project.pbxproj").write_text(
                """
                MARKETING_VERSION = 1.2;
                CURRENT_PROJECT_VERSION = 45;
                """,
                encoding="utf-8",
            )

            build = prepare_accessibility_performance_evidence.read_build_string(repo)

        self.assertEqual(build, "Atria 1.2 (45)")

    def test_cli_refuses_to_overwrite_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            out = repo / "summary.draft.json"
            out.write_text("{}\n", encoding="utf-8")

            result = subprocess.run(
                [
                    "python3",
                    str(Path(__file__).resolve().parent / "tools" / "prepare_accessibility_performance_evidence.py"),
                    "--repo",
                    str(repo),
                    "--out",
                    str(out),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(out.read_text(encoding="utf-8")), {})

    def test_measured_inputs_can_populate_a_non_final_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            trace = repo / "docs/evidence/accessibility-performance/trace.trace"
            trace.parent.mkdir(parents=True)
            trace.write_text("trace placeholder\n", encoding="utf-8")

            manifest = prepare_accessibility_performance_evidence.apply_measured_inputs(
                prepare_accessibility_performance_evidence.default_manifest(repo, "2026-06-22T12:00:00Z"),
                repo,
                dashboard_scroll_fps=59.5,
                passed_checks=["light_mode", "dark_mode"],
                instruments_trace=trace,
                notes="Measured Release scroll and visual checks on cabled iPhone 15 Pro.",
            )

        self.assertEqual(manifest["dashboard_scroll_fps"], 59.5)
        self.assertEqual(manifest["instruments_trace"], "docs/evidence/accessibility-performance/trace.trace")
        self.assertTrue(manifest["accessibility_checks"]["light_mode"])
        self.assertTrue(manifest["accessibility_checks"]["dark_mode"])
        self.assertFalse(manifest["accessibility_checks"]["reduce_motion"])
        self.assertIn("Measured Release", manifest["notes"])

    def test_final_manifest_reports_blockers_until_all_measured_fields_are_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            manifest = prepare_accessibility_performance_evidence.default_manifest(repo, "2026-06-22T12:00:00Z")

            blockers = prepare_accessibility_performance_evidence.manifest_blockers(repo, manifest)

        self.assertIn("dashboard_scroll_fps", blockers)
        self.assertIn("instruments_trace_file", blockers)
        self.assertIn("accessibility_reduce_motion", blockers)

    def test_cli_final_requires_real_trace_passing_checks_and_fps(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init"], cwd=repo, check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            (repo / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "Initial"], cwd=repo, check=True, stdout=subprocess.DEVNULL)
            out = repo / "summary.json"

            failed = subprocess.run(
                [
                    "python3",
                    str(Path(__file__).resolve().parent / "tools" / "prepare_accessibility_performance_evidence.py"),
                    "--repo",
                    str(repo),
                    "--out",
                    str(out),
                    "--final",
                    "--force",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse(out.exists())

            trace = repo / "trace.trace"
            trace.write_text("trace placeholder\n", encoding="utf-8")
            passed = subprocess.run(
                [
                    "python3",
                    str(Path(__file__).resolve().parent / "tools" / "prepare_accessibility_performance_evidence.py"),
                    "--repo",
                    str(repo),
                    "--out",
                    str(out),
                    "--final",
                    "--force",
                    "--all-accessibility-checks-pass",
                    "--dashboard-scroll-fps",
                    "60",
                    "--instruments-trace",
                    str(trace),
                    "--app-commit",
                    "installed-app",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

            self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
            data = json.loads(out.read_text(encoding="utf-8"))

        self.assertEqual(data["dashboard_scroll_fps"], 60.0)
        self.assertEqual(data["app_commit"], "installed-app")
        self.assertTrue(all(data["accessibility_checks"].values()))
        self.assertTrue(data["instruments_trace"].endswith("trace.trace"))


if __name__ == "__main__":
    unittest.main()
