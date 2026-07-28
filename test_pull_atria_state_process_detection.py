import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
PULL_SCRIPT = ROOT / "pull_atria_state.sh"


class PullAtriaStateProcessDetectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.fake_devicectl = self.root / "devicectl"
        self.fake_devicectl.write_text(
            """#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-} ${2:-} ${3:-}" == "device info processes" ]]; then
  cat "$FAKE_PROCESSES_FILE"
  exit 0
fi

if [[ "${1:-} ${2:-} ${3:-}" == "device info apps" ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--json-output" ]]; then
      printf '{"result":{"apps":[]}}\\n' > "$2"
      exit 0
    fi
    shift
  done
fi

exit 1
"""
        )
        self.fake_devicectl.chmod(0o755)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def pull(self, process_listing: str) -> str:
        process_file = self.root / "processes-fixture.txt"
        process_file.write_text(process_listing)
        evidence_directory = self.root / "evidence"
        environment = os.environ.copy()
        environment.update(
            {
                "ATRIA_DEVICETCL": str(self.fake_devicectl),
                "FAKE_PROCESSES_FILE": str(process_file),
            }
        )
        result = subprocess.run(
            [
                str(PULL_SCRIPT),
                "--device",
                "fixture-device",
                "--runtime-only",
                "--evidence-dir",
                str(evidence_directory),
            ],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return (evidence_directory / "pull-summary.txt").read_text()

    def test_widget_alone_is_not_reported_as_the_main_app(self) -> None:
        summary = self.pull(
            "52277   /private/var/containers/Bundle/Application/UUID/"
            "Atria.app/PlugIns/AtriaWidget.appex/AtriaWidget\n"
        )

        self.assertIn("process_status=not_listed\n", summary)
        self.assertIn("process_name_status=not_atria\n", summary)
        self.assertIn("atria_main_process=0\n", summary)
        self.assertIn("atria_widget_process=1\n", summary)
        self.assertNotIn("process_status=running\n", summary)

    def test_main_app_remains_reported_when_widget_is_also_running(self) -> None:
        summary = self.pull(
            "52277   /private/var/containers/Bundle/Application/UUID/"
            "Atria.app/PlugIns/AtriaWidget.appex/AtriaWidget\n"
            "52335   /private/var/containers/Bundle/Application/UUID/"
            "Atria.app/Atria\n"
        )

        self.assertIn("process_status=running\n", summary)
        self.assertIn("process_name_status=atria\n", summary)
        self.assertIn("atria_main_process=1\n", summary)
        self.assertIn("atria_widget_process=1\n", summary)


if __name__ == "__main__":
    unittest.main()
