#!/usr/bin/env python3
import base64
import hashlib
import json
import sqlite3
import subprocess
import tempfile
import unittest
import uuid
import zlib
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent
VERIFY = ROOT / "tools" / "verify_gate2_release_artifacts.py"
GAP = "7f8f3af8-b06a-4f58-a80e-dd211db8470a"
START = 1_900_000_000
END = START + 10
APPLE_OFFSET = 978_307_200
DECODER = "whoop4_0x2f_openstrap_v1_v24"
SHA_A = "a" * 64
SHA_B = "b" * 64
SHA_C = "c" * 64
SHA_D = "d" * 64


def canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def iso(value):
    return datetime.fromtimestamp(value, tz=timezone.utc).isoformat().replace("+00:00", "Z")


class Gate2ReleaseArtifactVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.pre = self.root / "pre.json"
        self.mid = self.root / "mid.json"
        self.post = self.root / "post.json"
        self.authority = self.root / "authority.json"
        self.anchor = self.root / "anchor.json"
        self.raw = self.root / "raw-chunk.jsonl"
        self.identity = self.root / "identity.jsonl"
        self.durability = self.root / "identity-durability.json"
        self.admission = self.root / "admission.sqlite"
        self.publication = self.root / "publication"
        self.publication.mkdir()

        self.pre.write_bytes(canonical({
            "corruptionSHA256": None, "generation": 1, "state": "valid",
            "version": 2, "windows": [],
        }))
        window = {
            "id": GAP, "start": START - APPLE_OFFSET, "end": END - APPLE_OFFSET,
            "reason": "controlled_outage",
            "coveredSecondBitsBase64": base64.b64encode(b"\0\0").decode(),
        }
        mid = {
            "corruptionSHA256": None, "generation": 2, "state": "valid",
            "version": 2, "windows": [window],
        }
        mid_raw = canonical(mid)
        self.mid.write_bytes(mid_raw)
        self.post.write_bytes(canonical({
            "corruptionSHA256": None, "generation": 3, "state": "valid",
            "version": 2, "windows": [],
        }))

        raw_lines = []
        raw_offsets = {}
        raw_offset = 0
        for second in range(10):
            key = f"history-key-{second}"
            row = {
                "_atriaHistoryKey": key,
                "_atriaHistoryObservedAtUnix": END + 2 + second / 20,
                "clockCorrectedUnix7": START + second,
                "clockCorrectionStatus": "clock_ref_present",
                "currentSessionUsable": True,
                "gravityValidated": True,
                "layoutVersion": DECODER,
                "metricUsable": True,
                "schema": 3,
                "source": "0x2f",
                "subsec11": 0,
                "unix7": START + second,
                "whoofHR17": 70,
            }
            line = canonical(row) + b"\n"
            raw_lines.append(line)
            raw_offsets[key] = (raw_offset, line)
            raw_offset += len(line)
        raw_data = b"".join(raw_lines)
        self.raw.write_bytes(raw_data)
        raw_sha = digest(raw_data)

        index_lines = []
        for second in range(10):
            key = f"history-key-{second}"
            offset, line = raw_offsets[key]
            index_lines.append(canonical({
                "archivePath": f"/device/path/{self.raw.name}",
                "key": key,
                "lineCRC32": zlib.crc32(line),
                "lineLength": len(line),
                "lineOffset": offset,
                "observedAtUnix": END + 2 + second / 20,
                "version": 2,
            }) + b"\n")
        self.identity.write_bytes(b"".join(index_lines))

        raw_store = {
            "storeIdentifier": "raw", "snapshotSHA256": SHA_A,
            "durableSequence": 7, "batchKeysSHA256": SHA_D,
            "byteCount": len(raw_data), "recordCount": 10,
            "observedIdentityCount": 10, "fsyncedAtUnix": END + 3,
        }
        identity_store = {
            "storeIdentifier": "identity", "snapshotSHA256": SHA_B,
            "durableSequence": 7, "batchKeysSHA256": SHA_D,
            "byteCount": self.identity.stat().st_size, "recordCount": 10,
            "observedIdentityCount": 10, "fsyncedAtUnix": END + 3,
        }
        admission_store = {
            "storeIdentifier": "admission", "snapshotSHA256": SHA_C,
            "durableSequence": 7, "batchKeysSHA256": SHA_C,
            "byteCount": 1000, "recordCount": 10,
            "observedIdentityCount": 10, "fsyncedAtUnix": END + 3.1,
        }
        admission_receipt = {
            "storeIdentifier": "admission", "snapshotSHA256": SHA_C,
            "durableSequence": 7, "durableOrdinal": 9,
            "recordCount": 10, "byteCount": 1000,
            "fsyncedAtUnix": END + 3.1,
            "rawArchiveSnapshotSHA256": SHA_A,
            "identityIndexSnapshotSHA256": SHA_B,
            "archiveReceiptChainSHA256": SHA_D,
        }
        stores = {
            "raw": raw_store, "identity": identity_store,
            "admission": admission_store, "admissionReceipt": admission_receipt,
        }
        self.durability.write_bytes(canonical({
            "version": 1, "previousChainSHA256": "e" * 64,
            "receipt": {
                "batchIdentifier": "batch-1", "raw": raw_store,
                "identity": identity_store,
            },
            "chainSHA256": SHA_D,
        }))

        connection = sqlite3.connect(self.admission)
        connection.executescript("""
            CREATE TABLE history_attempt (
                id TEXT PRIMARY KEY, strap_id TEXT, durable_ordinal INTEGER
            );
            CREATE TABLE history_archive_receipt (
                chain_digest TEXT, attempt_id TEXT, durable_sequence INTEGER,
                promoted_ordinal INTEGER, raw_digest TEXT, identity_digest TEXT,
                prefix_digest TEXT, record_count INTEGER, byte_count INTEGER
            );
        """)
        connection.execute(
            "INSERT INTO history_attempt VALUES (?, ?, ?)",
            ("attempt-1", "peripheral-1", 9),
        )
        connection.execute(
            "INSERT INTO history_archive_receipt VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (SHA_D, "attempt-1", 7, 9, SHA_A, SHA_B, SHA_C, 10, 1000),
        )
        connection.commit()
        connection.close()

        source = {
            "chunkID": "chunk-1", "rawSHA256": raw_sha,
            "firstTimestamp": iso(START), "lastTimestamp": iso(END - 1),
        }
        authority_receipts = []
        set_entries = []
        artifact_shas = []
        for authority_kind, receipt_kind in (
            ("activity", "activity"), ("daily_metrics", "dailyMetrics"),
            ("sleep", "sleep"), ("steps", "steps"), ("workout", "workout"),
        ):
            artifact_data = f"{authority_kind}-artifact".encode()
            artifact_sha = digest(artifact_data)
            artifact_name = f"consumer-artifact-{receipt_kind}-{artifact_sha}.bin"
            (self.publication / artifact_name).write_bytes(artifact_data)
            receipt_document = {
                "algorithmVersion": "v1",
                "artifactByteCount": len(artifact_data),
                "artifactFilename": artifact_name,
                "artifactSHA256": artifact_sha,
                "completionWatermark": iso(END + 4),
                "configurationSHA256": "f" * 64,
                "consumerSchemaVersion": 1,
                "dependencyEnd": iso(END),
                "dependencyStart": iso(START),
                "kind": receipt_kind,
                "outcome": "materialized",
                "recordCount": 1,
                "settledAt": iso(END + 5),
                "source": source,
                "version": 1,
            }
            receipt_data = canonical(receipt_document)
            receipt_sha = digest(receipt_data)
            receipt_name = f"consumer-receipt-{receipt_kind}-{receipt_sha}.json"
            (self.publication / receipt_name).write_bytes(receipt_data)
            authority_receipts.append({
                "kind": authority_kind, "receiptSHA256": receipt_sha,
                "artifactSHA256": artifact_sha,
                "sourceRawSnapshotSHA256": SHA_A,
                "sourceIdentitySnapshotSHA256": SHA_B,
                "sourceAdmissionSnapshotSHA256": SHA_C,
                "gapIdentifier": GAP, "attemptIdentifier": "attempt-1",
                "completionIdentifier": "completion-1",
                "commitIdentifier": receipt_name,
                "committedAtUnix": END + 5,
            })
            set_entries.append({
                "kind": receipt_kind, "receiptFilename": receipt_name,
                "receiptSHA256": receipt_sha,
            })
            artifact_shas.append(artifact_sha)
        authority_receipts.sort(key=lambda item: item["kind"])
        set_entries.sort(key=lambda item: item["kind"])
        source_key = digest(f"chunk-1|{raw_sha}".encode())
        receipt_set = {"version": 1, "source": source, "entries": set_entries}
        set_data = canonical(receipt_set)
        set_sha = digest(set_data)
        set_name = f"consumer-set-{source_key}-{set_sha}.json"
        (self.publication / set_name).write_bytes(set_data)
        (self.publication / f"consumer-set-current-{source_key}.json").write_bytes(
            canonical({
                "version": 1, "source": source, "setFilename": set_name,
                "setSHA256": set_sha,
            })
        )

        indexes = ",".join(map(str, range(10))).encode()
        transport = {
            "peripheralIdentifier": "peripheral-1", "strapIdentity": "strap-1",
            "transportNonce": "nonce-1", "transportGeneration": 8,
            "clockCommandSequence": 2,
            "clockCommandRequestedAtUnix": END + 0.1,
            "clockWriteCompletedAtUnix": END + 0.2,
            "clockResponseSequence": 2, "deviceClockUnix": END - 1,
            "clockWallUnix": END + 0.5,
            "clockResponseReceivedAtUnix": END + 0.6,
            "fullDrainCommandSequence": 3,
            "fullDrainCommandRequestedAtUnix": END + 0.7,
            "fullDrainWriteCompletedAtUnix": END + 1,
            "historyStartSequence": 4,
            "historyStartReceivedAtUnix": END + 1.1,
        }
        value = {
            "version": 1,
            "authority": {
                "version": 1, "authorityIdentifier": "authority-1",
                "createdAtUnix": END + 1,
                "gap": {
                    "gapIdentifier": GAP, "gapLedgerGeneration": 2,
                    "gapLedgerSnapshotSHA256": digest(mid_raw),
                    "startUnix": START, "endUnix": END,
                    "reason": "controlled_outage", "pending": True,
                },
                "attempt": {
                    "attemptIdentifier": "attempt-1", "attemptNumber": 1,
                    "peripheralIdentifier": "peripheral-1",
                    "strapIdentity": "strap-1", "transportNonce": "nonce-1",
                    "transportGeneration": 8,
                    "fullDrainCommandSHA256": "1" * 64,
                    "commandWriteCompletedAtUnix": END + 1,
                    "transportAuthority": transport,
                },
                "configuration": {
                    "cadenceSeconds": 1, "minimumDensityPercent": 90,
                    "maximumGapSeconds": 3, "maximumP95GapSeconds": 1,
                    "maximumGapDurationSeconds": 1_123_200,
                    "requiredConsumerKinds": [
                        "activity", "daily_metrics", "sleep", "steps", "workout"
                    ],
                },
                "boundaries": [{
                    "boundaryIdentifier": "boundary-1",
                    "historyEndSHA256": "2" * 64,
                    "expectedACKSHA256": "3" * 64,
                    "stores": stores, "fsyncedAtUnix": END + 3.1,
                    "ackAttempt": 1, "ackCompletedAtUnix": END + 3.2,
                }],
                "historyComplete": {
                    "completionIdentifier": "completion-1",
                    "notificationSHA256": "4" * 64,
                    "acknowledgedBoundaryCount": 1, "stores": stores,
                    "receivedAtUnix": END + 4,
                    "terminalBatchNumber": 1, "durableSequence": 7,
                },
                "coverageProof": {
                    "version": 1, "gapIdentifier": GAP,
                    "attemptIdentifier": "attempt-1",
                    "transportNonce": "nonce-1", "transportGeneration": 8,
                    "rawSnapshotSHA256": SHA_A,
                    "identitySnapshotSHA256": SHA_B,
                    "admissionSnapshotSHA256": SHA_C,
                    "decoderIdentifier": DECODER, "decoderVersion": 3,
                    "coveredBucketBits": base64.b64encode(b"\xff\x03").decode(),
                    "timestampSetSHA256": digest(indexes),
                    "observedBuckets": 10, "expectedBuckets": 10,
                    "densityPercent": 100, "maximumGapSeconds": 1,
                    "p95GapSeconds": 1, "firstTimestampUnix": START,
                    "lastTimestampUnix": END - 1,
                },
                "publication": {
                    "chunkID": "chunk-1", "terminalBatchNumber": 1,
                    "durableSequence": 7, "completedAtUnix": END + 4,
                    "rawSeal": {
                        "drainGeneration": 8, "contentSHA256": raw_sha,
                        "byteCount": len(raw_data), "rowCount": 10,
                        "firstTimestampUnix": START,
                        "lastTimestampUnix": END - 1,
                    },
                    "completion": {
                        "generation": 1, "catalogGeneration": 2,
                        "catalogSnapshotSHA256": "5" * 64,
                        "aggregateSnapshotSHA256": "6" * 64,
                    },
                    "projections": {
                        "completionGeneration": 1, "inspectedSourceCount": 1,
                        "receiptCount": 5,
                        "artifactSHA256s": sorted(artifact_shas),
                    },
                    "status": "projectionsPublished",
                },
                "consumerCommit": {
                    "receiptSetSHA256": digest(canonical(authority_receipts)),
                    "receipts": authority_receipts,
                    "committedAtUnix": END + 5,
                },
                "pendingConsumerDependency": None,
                "terminalGapReconciliations": None,
                "gapResolutionPreparedAtUnix": END + 4.2,
                "resolvedAtUnix": END + 5.1,
                "status": "resolved",
            },
        }
        self.authority.write_bytes(canonical(value))
        self.anchor.write_bytes(canonical({
            "acceptedUnix": END + 6, "version": 1,
        }))

    def tearDown(self):
        self.temporary.cleanup()

    def command(self):
        return [
            "python3", str(VERIFY), "--gap-identifier", GAP,
            "--requested-start-unix", str(START),
            "--requested-end-unix", str(END),
            "--pre-ledger", str(self.pre), "--mid-ledger", str(self.mid),
            "--post-ledger", str(self.post), "--authority", str(self.authority),
            "--live-anchor", str(self.anchor), "--raw-artifact", str(self.raw),
            "--identity-artifact", str(self.identity),
            "--identity-durability-artifact", str(self.durability),
            "--admission-artifact", str(self.admission),
            "--publication-directory", str(self.publication),
            "--post-captured-at-unix", str(END + 7),
        ]

    def run_verifier(self):
        return subprocess.run(
            self.command(), cwd=ROOT, capture_output=True, text=True
        )

    def mutate_json(self, path, mutation):
        value = json.loads(path.read_bytes())
        mutation(value)
        path.write_bytes(canonical(value))

    def test_passes_from_release_artifacts_without_a_console_log(self):
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("gate2_release_artifact_status=pass", result.stdout)
        self.assertIn("coverage_percent=100", result.stdout)
        self.assertIn("consumer_receipts=5", result.stdout)

    def test_accepts_exact_gap_resolution_while_consumers_are_pending(self):
        def pending(value):
            authority = value["authority"]
            authority["status"] = "gapResolvedConsumersPending"
            authority["consumerCommit"] = None
            authority["publication"]["status"] = "completionPublished"
            authority["publication"]["projections"] = None

        self.mutate_json(self.authority, pending)
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("consumer_receipts=0", result.stdout)

    def test_rejects_stale_or_mismatched_gap_authority(self):
        self.mutate_json(
            self.authority,
            lambda value: value["authority"]["gap"].update(
                {"gapLedgerGeneration": 1}
            ),
        )
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("authority_gap_ledger_binding_mismatch", result.stdout)

    def test_rejects_ack_before_fsync(self):
        self.mutate_json(
            self.authority,
            lambda value: value["authority"]["boundaries"][0].update(
                {"ackCompletedAtUnix": END + 2}
            ),
        )
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("boundary_0_fsync_ack_order_invalid", result.stdout)

    def test_rejects_archived_rows_not_observed_by_current_attempt(self):
        rows = []
        for line in self.raw.read_bytes().splitlines():
            row = json.loads(line)
            row["_atriaHistoryObservedAtUnix"] = END - 1
            rows.append(canonical(row) + b"\n")
        raw_data = b"".join(rows)
        self.raw.write_bytes(raw_data)
        self.mutate_json(
            self.authority,
            lambda value: value["authority"]["publication"]["rawSeal"].update({
                "contentSHA256": digest(raw_data), "byteCount": len(raw_data),
            }),
        )
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("coverage_row_not_observed_by_bound_attempt", result.stdout)
        self.assertIn("coverage_continuity_below_policy", result.stdout)

    def test_rejects_missing_exact_gap_cas(self):
        self.post.write_bytes(self.mid.read_bytes())
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("post_ledger_gap_cas_absent", result.stdout)

    def test_rejects_stale_live_anchor(self):
        self.anchor.write_bytes(canonical({
            "acceptedUnix": END + 3, "version": 1,
        }))
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("live_anchor_not_fresh_after_terminal", result.stdout)

    def test_rejects_tampered_consumer_artifact(self):
        artifact = next(self.publication.glob("consumer-artifact-activity-*.bin"))
        artifact.write_bytes(b"tampered")
        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertIn("consumer_artifact_digest_mismatch_activity", result.stdout)

    def test_optional_relaunch_rejects_immutable_core_mutation(self):
        relaunch_ledger = self.root / "relaunch-ledger.json"
        relaunch_authority = self.root / "relaunch-authority.json"
        relaunch_anchor = self.root / "relaunch-anchor.json"
        relaunch_ledger.write_bytes(self.post.read_bytes())
        value = json.loads(self.authority.read_bytes())
        value["authority"]["attempt"]["transportNonce"] = "mutated"
        relaunch_authority.write_bytes(canonical(value))
        relaunch_anchor.write_bytes(canonical({
            "acceptedUnix": END + 8, "version": 1,
        }))
        command = self.command() + [
            "--post-relaunch-ledger", str(relaunch_ledger),
            "--post-relaunch-authority", str(relaunch_authority),
            "--post-relaunch-live-anchor", str(relaunch_anchor),
            "--post-relaunch-captured-at-unix", str(END + 9),
        ]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("post_relaunch_authority_core_mutated", result.stdout)


if __name__ == "__main__":
    unittest.main()
