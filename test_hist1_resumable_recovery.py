#!/usr/bin/env python3
import base64
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
VERIFY = ROOT / "tools" / "verify_hist1_resumable_recovery.py"
RUNNER = ROOT / "tools" / "run_hist1_resumable_recovery.py"
GAP = "7f8f3af8-b06a-4f58-a80e-dd211db8470a"
START = 1_800_000_000
END = START + 120
APPLE_OFFSET = 978_307_200
SHA = "a" * 64
LAYOUT = "whoop4_0x2f_openstrap_v1_v24"
sys.path.insert(0, str(ROOT / "tools"))
from run_hist1_resumable_recovery import blocking_preexisting_window_ids  # noqa: E402


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def transport(generation):
    return {
        "peripheralIdentifier": "strap", "strapIdentity": "whoop4",
        "transportNonce": f"nonce-{generation}", "transportGeneration": generation,
        "clockCommandSequence": 4, "clockCommandRequestedAtUnix": END + 1,
        "clockWriteCompletedAtUnix": END + 1.1, "clockResponseSequence": 4,
        "deviceClockUnix": END - 10, "clockWallUnix": END + 2,
        "clockResponseReceivedAtUnix": END + 2.5,
        "fullDrainCommandSequence": 5, "fullDrainCommandRequestedAtUnix": END + 3,
        "fullDrainWriteCompletedAtUnix": END + 3.1,
        "historyStartSequence": 6, "historyStartReceivedAtUnix": END + 3.2,
    }


def trace(generation, terminal):
    prefix = "\n".join([
        f"ATRIADBG history_request_authority status=candidate_selected gap={GAP} reason=test action=clock_then_drain",
        f"ATRIADBG historyRange status=requested generation={generation} sequence=4 payload=00 attempt=1 mutation=0",
        f"ATRIADBG historyRange status=write_confirmed generation={generation} sequence=4 mutation=0",
        "ATRIADBG historyRange status=observed response_seq=5 request_seq_echo=4 matched=1 write=800 read=710 capacity=1000 pending=120 mutation=0 payload=aabb",
        f"ATRIADBG historyRange status=matched_clock_authority generation={generation} sequence=4 pending=120 device_unix={END - 10} drift_s=12 source=2200",
        f"ATRIADBG historyRange status=forward_backlog_available generation={generation} pending=120 action=monotonic_settle_then_1600",
        f"ATRIADBG historyRange status=post_response_settle_confirmed generation={generation} settle_s=2 clock_source=2200 action=send_verified_1600",
        f"ATRIADBG historical_full_drain_write status=confirmed generation={generation} sequence=5 command=1600 exact_interval_authority=0",
        f"ATRIADBG historyMeta status=start sequence=6 generation={generation}",
        f"ATRIADBG historical_full_drain_authority status=armed generation={generation} gap={GAP} clock_seq=4 drain_seq=5 history_start_seq=6",
        f'ATRIADBG historyDrain status=durable generation={generation} boundary=batch("enddata:aabb") rows_since_ack=60 error=nil',
        f"ATRIADBG historyAck status=sending key=enddata:aabb generation={generation} attempt=1 payload=01aabb write_mode=wr",
        f"ATRIADBG historyAck status=accepted key=enddata:aabb generation={generation} attempt=1 proof=confirmed_gatt_write_plus_logical_response",
    ]) + "\n"
    if not terminal:
        return prefix + "ATRIADBG ble status=disconnected gap_retained=1\n"
    return prefix + "\n".join([
        f"ATRIADBG historyTerminal status=received sequence=9 generation={generation} pending=0 action=reduce",
        f"ATRIADBG offline_sync status=complete reason=test_terminal generation={generation} live_restored=1",
        f"ATRIADBG historical_full_drain_reconcile gap={GAP} generation={generation} status=resolved density=100 maximum_gap=1 p95_gap=1",
        f"ATRIADBG historical_full_drain_publish status=resolved generation={generation} gap={GAP} receipts=5",
    ]) + "\n"


class ResumableRecoveryVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        phase_dirs = (
            ("pre-gap-full", "prepare"), ("pre-gap-runtime", "prepare"),
            ("mid-drain-full", "post-reconnect-drain"),
            ("mid-drain-runtime", "post-reconnect-drain"),
            ("interrupt-full", "interrupt"), ("interrupt-runtime", "interrupt"),
            ("post-resume-full", "resume-final"),
            ("post-resume-runtime", "resume-final"),
        )
        for name, phase in phase_dirs:
            directory = self.root / name
            directory.mkdir()
            (directory / "hist1-phase.json").write_text(
                json.dumps({"complete": True, "phase": phase}) + "\n"
            )
            (directory / "pull-summary.txt").write_text(
                "app_provenance_status=pass\nactive_journal_final_status=ok\n"
                + ("process_status=running\n" if name.endswith("runtime") else "")
            )
        self.marker = self.root / "marker.json"
        self.marker.write_text(json.dumps({"gapStartUnix": START, "reconnectUnix": END}))

        ledger = {
            "corruptionSHA256": None, "generation": 7, "state": "valid", "version": 2,
            "windows": [{
                "id": GAP, "start": START - APPLE_OFFSET, "end": END - APPLE_OFFSET,
                "reason": "link_lost", "coveredSecondBitsBase64": base64.b64encode(b"\0" * 15).decode(),
            }],
        }
        raw = canonical(ledger)
        digest = hashlib.sha256(raw).hexdigest()
        pre_ledger = dict(ledger, generation=6, windows=[])
        directory = self.root / "pre-gap-full" / "historical-gap-ledger-v2"
        directory.mkdir()
        (directory / "historical-gap-ledger-v2.json").write_bytes(canonical(pre_ledger))
        for name in ("mid-drain-full", "interrupt-full"):
            directory = self.root / name / "historical-gap-ledger-v2"
            directory.mkdir()
            (directory / "historical-gap-ledger-v2.json").write_bytes(raw)
        post_ledger = dict(ledger, generation=9, windows=[])
        directory = self.root / "post-resume-full" / "historical-gap-ledger-v2"
        directory.mkdir()
        (directory / "historical-gap-ledger-v2.json").write_bytes(canonical(post_ledger))

        def write_authority(name, generation, resolved):
            attempt_id = f"attempt-{generation}"
            nonce = f"nonce-{generation}"
            completion_id = f"completion-{generation}"
            receipts = [{
                "kind": kind, "receiptSHA256": SHA, "artifactSHA256": SHA,
                "sourceRawSnapshotSHA256": SHA, "sourceIdentitySnapshotSHA256": SHA,
                "sourceAdmissionSnapshotSHA256": SHA, "gapIdentifier": GAP,
                "attemptIdentifier": attempt_id, "completionIdentifier": completion_id,
                "commitIdentifier": f"commit-{kind}",
            } for kind in ("activity", "daily_metrics", "sleep", "steps", "workout")]
            seals = {
                kind: {"storeIdentifier": kind, "snapshotSHA256": SHA,
                       "durableSequence": 8, "batchKeysSHA256": SHA,
                       "observedIdentityCount": 120}
                for kind in ("raw", "identity", "admission")
            }
            indexes = ",".join(map(str, range(120))).encode()
            value = {
                "authority": {
                    "gap": {"gapIdentifier": GAP, "gapLedgerGeneration": 7,
                            "gapLedgerSnapshotSHA256": digest, "startUnix": START,
                            "endUnix": END, "reason": "link_lost", "pending": True},
                    "attempt": {"attemptIdentifier": attempt_id,
                                "transportNonce": nonce,
                                "transportGeneration": generation,
                                "transportAuthority": transport(generation)},
                    "status": "resolved" if resolved else "draining",
                    "coverageProof": ({"gapIdentifier": GAP, "densityPercent": 100,
                                       "maximumGapSeconds": 1, "p95GapSeconds": 1,
                                       "observedBuckets": 120, "expectedBuckets": 120,
                                       "coveredBucketBits": base64.b64encode(b"\xff" * 15).decode(),
                                       "timestampSetSHA256": hashlib.sha256(indexes).hexdigest(),
                                       "firstTimestampUnix": START,
                                       "lastTimestampUnix": END - 1,
                                       "attemptIdentifier": attempt_id,
                                       "transportNonce": nonce,
                                       "transportGeneration": generation,
                                       "rawSnapshotSHA256": SHA,
                                       "identitySnapshotSHA256": SHA,
                                       "admissionSnapshotSHA256": SHA}
                                      if resolved else None),
                    "historyComplete": ({"completionIdentifier": completion_id,
                                         "stores": seals} if resolved else None),
                    "consumerCommit": ({"receipts": receipts} if resolved else None),
                    "resolvedAtUnix": END + 20 if resolved else None,
                }
            }
            directory = self.root / name / "historical-full-drain-authority-v1"
            directory.mkdir()
            (directory / "historical-full-drain-coverage-authority-v1.json").write_text(
                json.dumps(value)
            )

        write_authority("interrupt-full", 9, False)
        write_authority("post-resume-full", 10, True)
        segments = self.root / "post-resume-full" / "historical-archive-segments"
        segments.mkdir()
        rows = []
        for second in range(120):
            rows.append({"schema": 3, "source": "0x2f", "layoutVersion": LAYOUT,
                         "unix7": START + second, "clockCorrectedUnix7": START + second,
                         "clockCorrectionStatus": "clock_ref_present", "gravityValidated": True,
                         "whoofHR17": 61, "metricUsable": True, "currentSessionUsable": True,
                         "_atriaHistoryKey": f"key-{second}"})
        (segments / "segment.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        with (self.root / "post-resume-full" / "pull-summary.txt").open("a") as handle:
            handle.write(
                f"historical_archive_validated_metric_layouts={LAYOUT}\n"
                "historical_archive_identity_duplicate_keys=0\n"
            )
        self.interrupt_log = self.root / "interrupt.log"
        self.resume_log = self.root / "resume.log"
        self.interrupt_log.write_text(trace(9, False))
        self.resume_log.write_text(trace(10, True))

    def tearDown(self):
        self.temp.cleanup()

    def command(self):
        return ["python3", str(VERIFY), "--marker", str(self.marker),
                "--pre-gap-full", str(self.root / "pre-gap-full"),
                "--mid-drain-full", str(self.root / "mid-drain-full"),
                "--interrupt-full", str(self.root / "interrupt-full"),
                "--post-resume-full", str(self.root / "post-resume-full"),
                "--interrupted-log", str(self.interrupt_log),
                "--resumed-log", str(self.resume_log)]

    def test_accepts_bound_12_second_clock_drift_and_interrupted_resume(self):
        result = subprocess.run(self.command(), cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("hist1_resumable_recovery_status=pass", result.stdout)
        self.assertIn("coverage_percent=100", result.stdout)
        self.assertIn("interrupted_generation=9", result.stdout)
        self.assertIn("resumed_generation=10", result.stdout)

    def test_rejects_authority_borrowed_from_an_older_gap(self):
        path = next((self.root / "post-resume-full").rglob(
            "historical-full-drain-coverage-authority-v1.json"))
        value = json.loads(path.read_text())
        value["authority"]["gap"]["gapIdentifier"] = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        path.write_text(json.dumps(value))
        result = subprocess.run(self.command(), cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("post_authority_gap_uuid_mismatch", result.stdout)

    def test_rejects_gap_uuid_that_existed_before_manual_trial(self):
        pre_path = next((self.root / "pre-gap-full").rglob(
            "historical-gap-ledger-v2.json"
        ))
        mid_path = next((self.root / "mid-drain-full").rglob(
            "historical-gap-ledger-v2.json"
        ))
        pre = json.loads(mid_path.read_text())
        pre["generation"] = 6
        pre_path.write_bytes(canonical(pre))
        result = subprocess.run(self.command(), cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("controlled_gap_uuid_existed_before_manual_gap", result.stdout)

    def test_rejects_zero_rows_and_does_not_retire_by_transport_success(self):
        next((self.root / "post-resume-full" / "historical-archive-segments").glob("*.jsonl")).write_text("")
        result = subprocess.run(self.command(), cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("strap_returned_zero_metric_rows", result.stdout)
        self.assertIn("exact_gap_density_below_90_percent", result.stdout)


class ResumableRecoveryOrchestratorStaticTests(unittest.TestCase):
    def test_defaults_to_non_mutating_dry_run(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            result = subprocess.run(
                ["python3", str(RUNNER), "prepare", "--run", str(run)],
                cwd=ROOT, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("hist1_orchestrator_mode=dry_run", result.stdout)
            self.assertIn("device_mutation=none", result.stdout)
            self.assertFalse(run.exists())

    def test_execute_prepare_requires_console_log_before_any_pull(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            result = subprocess.run(
                [
                    "python3", str(RUNNER), "prepare", "--run", str(run),
                    "--device", "fake-device", "--execute",
                ],
                cwd=ROOT, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("prepare --execute requires --live-log", result.stderr)
            self.assertFalse(run.exists())

    def test_runner_has_no_app_lifecycle_or_radio_commands(self):
        text = RUNNER.read_text(encoding="utf-8")
        for forbidden in ("terminate-existing", "device process launch", "kill(",
                          "forget device"):
            self.assertNotIn(forbidden, text)

    def test_preexisting_closed_candidate_fails_before_controlled_gap(self):
        ledger = {"windows": [
            {"id": "old", "end": 123, "reason": "link_lost"},
            {"id": "open", "end": None, "reason": "link_lost"},
            {"id": "legacy", "end": 456,
             "reason": "coalesced_unresolved_history"},
        ]}
        self.assertEqual(blocking_preexisting_window_ids(ledger), ["old", "open"])

    def test_open_only_window_blocks_before_controlled_gap(self):
        ledger = {"windows": [
            {"id": "open", "end": None, "reason": "link_lost"},
        ]}
        self.assertEqual(blocking_preexisting_window_ids(ledger), ["open"])

    def test_exact_coalesced_window_blocks_but_legacy_envelope_does_not(self):
        ledger = {"windows": [
            {"id": "exact", "end": 123,
             "reason": "coalesced_unresolved_history",
             "expectedSecondBitsBase64": "AQ=="},
            {"id": "legacy", "end": 456,
             "reason": "coalesced_unresolved_history"},
        ]}
        self.assertEqual(blocking_preexisting_window_ids(ledger), ["exact"])


if __name__ == "__main__":
    unittest.main()
