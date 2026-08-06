#!/usr/bin/env python3
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
RUNNER = ROOT / "tools" / "run_hist1_acceptance_after_reconnect.sh"


class Hist1ConsoleLifecycleStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runner = RUNNER.read_text(encoding="utf-8")

    def test_console_capture_is_detached_from_harness_signal_domain(self):
        for token in (
            "stdin=subprocess.DEVNULL",
            "stdout=log",
            "stderr=subprocess.STDOUT",
            "start_new_session=True",
            "close_fds=True",
            '"--console"',
            '"--timeout", "240"',
        ):
            self.assertIn(token, self.runner)

    def test_cleanup_never_signals_or_waits_on_console_process(self):
        match = re.search(
            r"^cleanup_console\(\) \{(?P<body>.*?)^\}",
            self.runner,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        commands = [
            line.strip()
            for line in body.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        self.assertEqual(commands, [":"])

    def test_console_writes_final_evidence_paths_without_tempfile_cleanup(self):
        self.assertIn(
            '"$device_id" "$bundle_id" "$recovery_log_capture"',
            self.runner,
        )
        self.assertIn('if [[ -e "$recovery_log_capture" ]]', self.runner)
        self.assertIn('mv "$recovery_log_capture" "$recovery_log"', self.runner)
        self.assertIn(
            "console_capture_lifecycle=detached_new_session_natural_devicectl_timeout",
            self.runner,
        )
        self.assertNotIn("recovery_log_tmp", self.runner)
        self.assertNotIn("launch_json_tmp", self.runner)
        self.assertNotIn("--json-output", self.runner)

    def test_all_output_collisions_fail_before_the_terminating_launch(self):
        collision_guard = self.runner.index("for reserved_path in")
        launch = self.runner.index("console_pid=$(python3")
        self.assertLess(collision_guard, launch)
        for token in (
            '"$evidence_dir"',
            '"$screenshot_dir"',
            '"$recovery_log_capture"',
            '"$pre_relaunch_dir"',
        ):
            self.assertIn(token, self.runner[collision_guard:launch])
        self.assertNotIn("rm -rf", self.runner)


if __name__ == "__main__":
    unittest.main()
