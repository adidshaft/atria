#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
HELPER_PATH = ROOT / "tools" / "v4_morning_acceptance.py"
RUNNER = ROOT / "tools" / "run_v4_morning_acceptance.sh"
SPEC = importlib.util.spec_from_file_location("v4_morning_acceptance", HELPER_PATH)
assert SPEC and SPEC.loader
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


def valid_summary(*, full: bool = False) -> str:
    rows = {
        "process_status": "running",
        "process_name_status": "atria",
        "app_provenance_status": "pass",
        "active_journal_final_status": "ok",
        "active_journal_final_source": "segmented_canonical",
        "active_journal_torn_copy_status": "none",
        "active_journal_continuity_status": "active",
        "active_journal_freshness": "fresh",
        "active_journal_samples": "420",
        "active_journal_segment_reconstruction_status": "ok",
        "active_journal_segment_integrity_status": "ok",
        "active_journal_segment_sequence_status": "ok",
        "active_journal_segment_sample_continuity_status": "ok",
        "active_journal_segment_rr_continuity_status": "ok",
        "runtime_evidence_validation_status": "ok",
    }
    if full:
        rows.update({
            "historical_archive_summary_status": "ok",
            "historical_archive_parse_errors": "0",
            "historical_archive_identity_summary_status": "ok",
            "historical_archive_identity_duplicate_keys": "0",
            "historical_archive_identity_parse_errors": "0",
        })
    return "".join(f"{key}={value}\n" for key, value in rows.items())


def metadata(bundle_path: str, data_path: str = "/private/data") -> dict:
    return {
        "result": {
            "apps": [{
                "bundleIdentifier": "com.adidshaft.atria",
                "bundleContainerPath": bundle_path,
                "dataContainerPath": data_path,
                "url": f"file://{bundle_path}/Atria.app/",
                "appGroupIdentifiers": ["group.com.adidshaft.atria"],
                "version": "1.0",
                "bundleVersion": "1",
            }]
        }
    }


class AcceptanceHelperTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def summary(self, contents: str) -> Path:
        path = self.root / "pull-summary.txt"
        path.write_text(contents, encoding="utf-8")
        return path

    def test_runtime_and_full_summaries_pass_only_with_all_integrity_gates(self):
        HELPER.check_summary(self.summary(valid_summary()), "runtime")
        HELPER.check_summary(self.summary(valid_summary(full=True)), "full")

    def test_summary_refuses_each_authority_or_integrity_failure(self):
        failures = {
            "process_status": "not_listed",
            "app_provenance_status": "fail",
            "active_journal_torn_copy_status": "detected",
            "active_journal_segment_sequence_status": "noncontiguous",
            "active_journal_segment_rr_continuity_status": "noncontiguous",
            "runtime_evidence_validation_status": "invalid",
            "active_journal_samples": "0",
        }
        for key, replacement in failures.items():
            with self.subTest(key=key):
                text = re.sub(rf"^{re.escape(key)}=.*$", f"{key}={replacement}",
                              valid_summary(), flags=re.MULTILINE)
                with self.assertRaises(HELPER.AcceptanceError):
                    HELPER.check_summary(self.summary(text), "runtime")

    def test_runtime_summary_refuses_empty_runtime_evidence(self):
        text = valid_summary().replace(
            "runtime_evidence_validation_status=ok",
            "runtime_evidence_validation_status=empty",
        )
        with self.assertRaises(HELPER.AcceptanceError):
            HELPER.check_summary(self.summary(text), "runtime")

    def test_full_summary_refuses_archive_parse_or_identity_duplicates(self):
        for key in (
            "historical_archive_parse_errors",
            "historical_archive_identity_duplicate_keys",
            "historical_archive_identity_parse_errors",
        ):
            with self.subTest(key=key):
                text = valid_summary(full=True).replace(f"{key}=0", f"{key}=1")
                with self.assertRaises(HELPER.AcceptanceError):
                    HELPER.check_summary(self.summary(text), "full")

    def test_metadata_requires_exact_group_and_preserves_data_domain(self):
        source = self.root / "metadata.json"
        source.write_text(json.dumps(metadata("/private/bundle-a")), encoding="utf-8")
        before = HELPER.extract_metadata(
            source, "com.adidshaft.atria", "group.com.adidshaft.atria"
        )
        source.write_text(json.dumps(metadata("/private/bundle-b")), encoding="utf-8")
        after = HELPER.extract_metadata(
            source, "com.adidshaft.atria", "group.com.adidshaft.atria"
        )
        HELPER.compare_metadata(before, after)
        self.assertEqual(
            before["app_group_container_path"],
            "coredevice://appGroupDataContainer/group.com.adidshaft.atria",
        )
        changed = dict(after, data_container_path="/private/new-data")
        with self.assertRaises(HELPER.AcceptanceError):
            HELPER.compare_metadata(before, changed)

    def test_metadata_refuses_missing_or_extra_app_group(self):
        for groups in ([], ["group.com.adidshaft.atria", "group.extra"]):
            value = metadata("/private/bundle")
            value["result"]["apps"][0]["appGroupIdentifiers"] = groups
            source = self.root / "metadata.json"
            source.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaises(HELPER.AcceptanceError):
                HELPER.extract_metadata(
                    source, "com.adidshaft.atria", "group.com.adidshaft.atria"
                )

    def test_console_requires_restore_and_two_nonregressing_compactions(self):
        console = self.root / "console.log"
        console.write_text(
            "ATRIADBG active_session_journal status=restored reason=launch samples=420 rr_values=10\n"
            "ATRIADBG active_session_journal status=saved reason=a samples=450 rr_values=10 "
            "delta_samples=30 delta_rr_values=0 compacted=1\n"
            "ATRIADBG active_session_journal status=saved reason=b samples=480 rr_values=10 "
            "delta_samples=30 delta_rr_values=0 compacted=1\n",
            encoding="utf-8",
        )
        result = HELPER.scan_console(console, 2, 420)
        self.assertEqual(result["journal_compactions"], 2)
        self.assertEqual(result["journal_latest_saved_samples"], 480)

    def test_console_hard_fails_save_failure_full_rebase_and_regression(self):
        cases = (
            "ATRIADBG active_session_journal status=save_failed next_action=retry_pending_delta\n",
            "ATRIADBG active_session_journal status=saved next_action=verified_full_rebase\n",
            "ATRIADBG active_session_journal status=restored reason=x samples=420\n"
            "ATRIADBG active_session_journal status=saved reason=a samples=500 compacted=1\n"
            "ATRIADBG active_session_journal status=saved reason=b samples=499 compacted=1\n",
        )
        for index, text in enumerate(cases):
            with self.subTest(index=index):
                console = self.root / f"console-{index}.log"
                console.write_text(text, encoding="utf-8")
                with self.assertRaises(HELPER.AcceptanceError):
                    HELPER.scan_console(console, 2, 420)

    def test_console_allows_count_reset_only_after_named_durable_boundary(self):
        console = self.root / "console.log"
        console.write_text(
            "ATRIADBG active_session_journal status=restored reason=x samples=420\n"
            "ATRIADBG active_session_journal status=saved reason=a samples=500 compacted=1\n"
            "ATRIADBG active_session_journal status=cleared reason=long_wear_retention_roll\n"
            "ATRIADBG active_session_journal status=saved reason=b samples=30 compacted=1\n",
            encoding="utf-8",
        )
        self.assertEqual(HELPER.scan_console(console, 2, 420)["journal_compactions"], 2)

    def test_manifest_excludes_itself(self):
        (self.root / "a.txt").write_text("a", encoding="utf-8")
        output = self.root / "evidence.sha256"
        HELPER.write_manifest(self.root, output)
        self.assertIn("a.txt", output.read_text(encoding="utf-8"))
        self.assertNotIn("evidence.sha256", output.read_text(encoding="utf-8"))


class RunnerMockTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.app = self.root / "Atria.app"
        self.app.mkdir()
        with (self.app / "Info.plist").open("wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": "com.adidshaft.atria",
                "CFBundleExecutable": "Atria",
            }, handle)
        self.binary = self.app / "Atria.debug.dylib"
        self.binary.write_bytes(b"signed-v4-candidate")
        self.sha = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.evidence = self.root / "evidence"
        self.command_log = self.root / "commands.log"
        self.device_state = self.root / "device-state"
        self.fake_codesign = self.root / "fake-codesign"
        self.fake_codesign.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.fake_pull = self.root / "fake-pull"
        self.fake_pull.write_text(
            """#!/bin/sh
set -eu
printf 'pull %s\\n' "$*" >> "$FAKE_COMMAND_LOG"
out=
full=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --evidence-dir) out=$2; shift 2 ;;
    --runtime-only) full=0; shift ;;
    *) shift ;;
  esac
done
mkdir -p "$out"
cp "$FAKE_RUNTIME_SUMMARY" "$out/pull-summary.txt"
if [ "$full" -eq 1 ]; then cat "$FAKE_FULL_EXTRA" >> "$out/pull-summary.txt"; fi
""",
            encoding="utf-8",
        )
        self.fake_devicectl = self.root / "fake-devicectl"
        self.fake_devicectl.write_text(
            """#!/bin/sh
set -eu
printf 'devicectl %s\\n' "$*" >> "$FAKE_COMMAND_LOG"
if [ "$1" = device ] && [ "$2" = info ] && [ "$3" = apps ]; then
  output=
  while [ "$#" -gt 0 ]; do
    case "$1" in --json-output) output=$2; shift 2 ;; *) shift ;; esac
  done
  if [ -f "$FAKE_DEVICE_STATE/installed" ]; then bundle=/private/bundle-new; else bundle=/private/bundle-old; fi
  if [ -f "$FAKE_DEVICE_STATE/data-changed" ]; then data=/private/data-new; else data=/private/data; fi
  sed -e "s|BUNDLE_PATH|$bundle|g" -e "s|DATA_PATH|$data|g" "$FAKE_METADATA_TEMPLATE" > "$output"
  exit 0
fi
if [ "$1" = device ] && [ "$2" = install ] && [ "$3" = app ]; then
  touch "$FAKE_DEVICE_STATE/installed"
  while [ "$#" -gt 0 ]; do
    case "$1" in --json-output) printf '{\"result\":{}}\\n' > "$2"; shift 2 ;; *) shift ;; esac
  done
  exit 0
fi
if [ "$1" = device ] && [ "$2" = info ] && [ "$3" = processes ]; then
  if [ -f "$FAKE_DEVICE_STATE/running" ]; then printf 'Atria com.adidshaft.atria /Atria.app/Atria\\n'; fi
  exit 0
fi
if [ "$1" = device ] && [ "$2" = process ] && [ "$3" = launch ]; then
  touch "$FAKE_DEVICE_STATE/running"
  printf 'ATRIADBG active_session_journal status=restored reason=launch samples=420 rr_values=10\\n'
  printf 'ATRIADBG active_session_journal status=saved reason=a samples=450 compacted=1\\n'
  printf 'ATRIADBG active_session_journal status=saved reason=b samples=480 compacted=1\\n'
  exit 0
fi
exit 9
""",
            encoding="utf-8",
        )
        for path in (self.fake_codesign, self.fake_pull, self.fake_devicectl):
            path.chmod(0o755)
        self.runtime_summary = self.root / "runtime-summary.txt"
        self.runtime_summary.write_text(valid_summary(), encoding="utf-8")
        self.full_extra = self.root / "full-extra.txt"
        self.full_extra.write_text(
            "historical_archive_summary_status=ok\n"
            "historical_archive_parse_errors=0\n"
            "historical_archive_identity_summary_status=ok\n"
            "historical_archive_identity_duplicate_keys=0\n"
            "historical_archive_identity_parse_errors=0\n",
            encoding="utf-8",
        )
        self.metadata_template = self.root / "metadata-template.json"
        value = metadata("BUNDLE_PATH", "DATA_PATH")
        value["result"]["apps"][0]["url"] = "file://BUNDLE_PATH/Atria.app/"
        self.metadata_template.write_text(json.dumps(value), encoding="utf-8")
        self.device_state.mkdir()

    def tearDown(self):
        self.scratch.cleanup()

    def environment(self) -> dict[str, str]:
        return {
            **os.environ,
            "ATRIA_CODESIGN": str(self.fake_codesign),
            "ATRIA_PULL_SCRIPT": str(self.fake_pull),
            "ATRIA_DEVICETCL": str(self.fake_devicectl),
            "ATRIA_LAUNCH_SETTLE_SECONDS": "1",
            "FAKE_COMMAND_LOG": str(self.command_log),
            "FAKE_DEVICE_STATE": str(self.device_state),
            "FAKE_RUNTIME_SUMMARY": str(self.runtime_summary),
            "FAKE_FULL_EXTRA": str(self.full_extra),
            "FAKE_METADATA_TEMPLATE": str(self.metadata_template),
        }

    def command(self, phase: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash", str(RUNNER), phase,
                "--device", "fake-device",
                "--bundle-id", "com.adidshaft.atria",
                "--app", str(self.app),
                "--candidate-sha256", self.sha,
                "--evidence-root", str(self.evidence),
                *extra,
            ],
            cwd=ROOT,
            env=self.environment(),
            capture_output=True,
            text=True,
            timeout=20,
        )

    def test_dry_run_never_calls_external_commands_or_creates_evidence(self):
        result = self.command("prepare", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("dry_run=1", result.stdout)
        self.assertFalse(self.evidence.exists())
        self.assertFalse(self.command_log.exists())

    def test_prepare_and_install_preserve_containers_and_rotate_bundle(self):
        prepared = self.command("prepare")
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        installed = self.command("install")
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        self.assertTrue((self.evidence / "02-install/phase-complete.json").is_file())
        self.assertIn(
            "container_continuity_status=pass",
            (self.evidence / "02-install/container-continuity.txt").read_text(),
        )

    def test_prepare_fails_closed_and_preserves_partial_evidence(self):
        self.runtime_summary.write_text(
            valid_summary().replace("app_provenance_status=pass", "app_provenance_status=fail"),
            encoding="utf-8",
        )
        result = self.command("prepare")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.evidence / "01-prepare/runtime-only/pull-summary.txt").is_file())
        self.assertFalse((self.evidence / "01-prepare/phase-complete.json").exists())
        self.assertEqual(self.command_log.read_text().count("pull "), 1)

    def test_corrupt_phase_receipt_is_not_treated_as_completed(self):
        prepared = self.command("prepare")
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        (self.evidence / "01-prepare/phase-complete.json").write_text("{}\n", encoding="utf-8")
        result = self.command("prepare")
        self.assertEqual(result.returncode, 73)
        self.assertIn("preserving it and refusing overwrite", result.stderr)

    def test_install_refuses_changed_data_container(self):
        self.assertEqual(self.command("prepare").returncode, 0)
        (self.device_state / "data-changed").touch()
        result = self.command("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed data_container_path", result.stderr)
        self.assertFalse((self.evidence / "02-install/phase-complete.json").exists())

    def test_launch_refuses_running_process_without_terminating_it(self):
        self.assertEqual(self.command("prepare").returncode, 0)
        self.assertEqual(self.command("install").returncode, 0)
        (self.device_state / "running").touch()
        result = self.command("launch")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already running", result.stderr)
        self.assertNotIn("device process launch", self.command_log.read_text())

    def test_all_phases_detach_launch_and_accept_two_compactions(self):
        result = self.command(
            "all", "--monitor-seconds", "5", "--poll-seconds", "1",
            "--minimum-compactions", "2",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.evidence / "04-monitor/phase-complete.json").is_file())
        self.assertIn(
            "journal_compactions=2",
            (self.evidence / "04-monitor/journal-monitor.txt").read_text(),
        )
        lifecycle = (self.evidence / "03-launch/console-lifecycle.txt").read_text()
        self.assertIn("never_signal_never_wait", lifecycle)
        command_log = self.command_log.read_text()
        self.assertIn("--atria-enable-step-calibration", command_log)
        self.assertNotIn("--terminate-existing", command_log)


class RunnerStaticTests(unittest.TestCase):
    def test_shell_is_syntactically_valid(self):
        result = subprocess.run(["bash", "-n", str(RUNNER)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_runner_contains_no_uninstall_delete_signal_or_terminate_existing(self):
        source = RUNNER.read_text(encoding="utf-8")
        self.assertNotRegex(source, r"device\s+uninstall")
        self.assertNotIn("--terminate-existing", source)
        self.assertNotRegex(source, r"(?m)^\s*(kill|pkill|killall|wait)\b")
        self.assertIn("start_new_session=True", source)
        self.assertIn("stdin=subprocess.DEVNULL", source)
        self.assertIn("console_signal_policy=never_signal_never_wait", source)

    def test_monitor_manifest_precedes_final_durable_pass_receipt(self):
        source = RUNNER.read_text(encoding="utf-8")
        start = source.index("run_monitor() {")
        monitor = source[start:source.index("case \"$phase\" in", start)]
        manifest = monitor.rindex('manifest --root "$directory"')
        receipt = monitor.rindex('complete_phase "$directory" "monitor"')
        status = monitor.rindex("phase=monitor status=pass")
        self.assertLess(manifest, receipt)
        self.assertLess(receipt, status)


if __name__ == "__main__":
    unittest.main()
