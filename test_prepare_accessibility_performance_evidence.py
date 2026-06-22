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
            (repo / "WhoopApp" / "WhoopApp.xcodeproj").mkdir(parents=True)
            (repo / "WhoopApp" / "Info.plist").write_text(
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
            (repo / "WhoopApp" / "WhoopApp.xcodeproj" / "project.pbxproj").write_text(
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


if __name__ == "__main__":
    unittest.main()
