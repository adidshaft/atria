#!/usr/bin/env python3
"""Fail-closed Gate 2 verification from Release-build artifacts only.

Normal Release builds do not emit ATRIADBG.  This verifier therefore accepts no
console log.  It binds one controlled gap to the canonical gap ledger, the
fsynced full-drain authority, the sealed raw JSONL chunk, its exact identity
index, the SQLite admission receipt, consumer publication artifacts, and the
independently-fsynced accepted-live anchor.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import sqlite3
import sys
import uuid
import zlib
from datetime import datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_hist1_acceptance import is_validated_metric_row  # noqa: E402


APPLE_EPOCH_OFFSET = 978_307_200.0
REQUIRED_CONSUMERS = {
    "activity": "activity",
    "daily_metrics": "dailyMetrics",
    "sleep": "sleep",
    "steps": "steps",
    "workout": "workout",
}


def canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def valid_sha(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    return result if math.isfinite(result) else None


def positive_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def normalized_uuid(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value)).lower()
    except ValueError:
        return None


def swift_date_unix(value: object) -> float | None:
    result = number(value)
    if result is None:
        return None
    return result + APPLE_EPOCH_OFFSET if result < 1_200_000_000 else result


def iso_unix(value: object) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


class Verification:
    def __init__(self) -> None:
        self.blockers: list[str] = []

    def fail(self, blocker: str) -> None:
        if blocker not in self.blockers:
            self.blockers.append(blocker)

    def json_file(
        self, path: Path, label: str, *, require_canonical: bool = True
    ) -> tuple[dict[str, Any], bytes]:
        try:
            raw = path.read_bytes()
            value = json.loads(raw)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError) as error:
            self.fail(f"{label}_unreadable_{type(error).__name__}")
            return {}, b""
        if not isinstance(value, dict):
            self.fail(f"{label}_not_object")
            return {}, raw
        if require_canonical:
            try:
                expected = canonical(value)
            except (TypeError, ValueError):
                expected = b""
            if raw != expected:
                self.fail(f"{label}_not_canonical")
        return value, raw


def ledger(
    verification: Verification, path: Path, label: str
) -> tuple[dict[str, Any], bytes]:
    value, raw = verification.json_file(path, label)
    if value.get("version") != 2 or value.get("state") != "valid":
        verification.fail(f"{label}_not_valid_v2")
    if positive_int(value.get("generation")) is None:
        verification.fail(f"{label}_generation_invalid")
    if not isinstance(value.get("windows"), list):
        verification.fail(f"{label}_windows_invalid")
    return value, raw


def ledger_windows(document: dict[str, Any], gap_id: str) -> list[dict[str, Any]]:
    return [
        item for item in document.get("windows", [])
        if isinstance(item, dict) and normalized_uuid(item.get("id")) == gap_id
    ]


def window_bounds(window: dict[str, Any]) -> tuple[float | None, float | None]:
    return swift_date_unix(window.get("start")), swift_date_unix(window.get("end"))


def expected_window_is_contiguous(
    window: dict[str, Any], start: float, end: float
) -> bool:
    encoded = window.get("expectedSecondBitsBase64")
    if encoded is None:
        return True
    if not isinstance(encoded, str):
        return False
    try:
        bits = base64.b64decode(encoded, validate=True)
    except ValueError:
        return False
    expected = max(1, math.ceil(end - start))
    return all(
        index // 8 < len(bits) and bits[index // 8] & (1 << (index % 8))
        for index in range(expected)
    )


def validate_transport(
    verification: Verification, attempt: dict[str, Any], gap_end: float
) -> None:
    transport = attempt.get("transportAuthority")
    if not isinstance(transport, dict):
        verification.fail("transport_authority_missing")
        return
    for key in ("peripheralIdentifier", "strapIdentity", "transportNonce",
                "transportGeneration"):
        if transport.get(key) != attempt.get(key):
            verification.fail(f"transport_{key}_attempt_mismatch")
    times = {
        key: number(transport.get(key))
        for key in (
            "clockCommandRequestedAtUnix", "clockWriteCompletedAtUnix",
            "clockResponseReceivedAtUnix", "deviceClockUnix", "clockWallUnix",
            "fullDrainCommandRequestedAtUnix", "fullDrainWriteCompletedAtUnix",
            "historyStartReceivedAtUnix",
        )
    }
    if any(value is None for value in times.values()):
        verification.fail("transport_times_invalid")
        return
    t = {key: float(value) for key, value in times.items() if value is not None}
    if (
        transport.get("clockCommandSequence") != transport.get("clockResponseSequence")
        or transport.get("fullDrainCommandSequence") == transport.get("clockCommandSequence")
        or transport.get("historyStartSequence") == transport.get("fullDrainCommandSequence")
    ):
        verification.fail("transport_sequences_invalid")
    if not (
        t["clockWriteCompletedAtUnix"] >= t["clockCommandRequestedAtUnix"]
        and t["clockResponseReceivedAtUnix"] >= t["clockCommandRequestedAtUnix"]
        and t["fullDrainCommandRequestedAtUnix"] >= t["clockWriteCompletedAtUnix"]
        and t["fullDrainCommandRequestedAtUnix"] >= t["clockResponseReceivedAtUnix"]
        and t["fullDrainWriteCompletedAtUnix"] >= t["fullDrainCommandRequestedAtUnix"]
        and t["historyStartReceivedAtUnix"] >= t["fullDrainCommandRequestedAtUnix"]
        and t["fullDrainWriteCompletedAtUnix"] >= gap_end
    ):
        verification.fail("transport_order_invalid")
    if abs(t["clockResponseReceivedAtUnix"] - t["clockWallUnix"]) > 2:
        verification.fail("transport_clock_response_stale")
    if abs(t["clockWallUnix"] - t["deviceClockUnix"]) > 24 * 60 * 60:
        verification.fail("transport_clock_drift_over_24h")
    if attempt.get("commandWriteCompletedAtUnix") != t["fullDrainWriteCompletedAtUnix"]:
        verification.fail("attempt_command_write_transport_mismatch")


def seal_valid(seal: object) -> bool:
    return (
        isinstance(seal, dict)
        and isinstance(seal.get("storeIdentifier"), str)
        and bool(seal["storeIdentifier"])
        and valid_sha(seal.get("snapshotSHA256"))
        and valid_sha(seal.get("batchKeysSHA256"))
        and positive_int(seal.get("durableSequence")) is not None
        and isinstance(seal.get("byteCount"), int)
        and seal["byteCount"] >= 0
        and isinstance(seal.get("recordCount"), int)
        and seal["recordCount"] >= 0
        and isinstance(seal.get("observedIdentityCount"), int)
        and seal["observedIdentityCount"] >= 0
        and (number(seal.get("fsyncedAtUnix")) or 0) > 0
    )


def validate_store_pair(
    verification: Verification, stores: object, label: str
) -> dict[str, Any]:
    if not isinstance(stores, dict):
        verification.fail(f"{label}_stores_missing")
        return {}
    raw = stores.get("raw")
    identity = stores.get("identity")
    admission = stores.get("admission")
    receipt = stores.get("admissionReceipt")
    for kind, value in (("raw", raw), ("identity", identity), ("admission", admission)):
        if not seal_valid(value):
            verification.fail(f"{label}_{kind}_seal_invalid")
    if not all(isinstance(value, dict) for value in (raw, identity, admission, receipt)):
        verification.fail(f"{label}_store_pair_invalid")
        return stores
    assert isinstance(raw, dict) and isinstance(identity, dict)
    assert isinstance(admission, dict) and isinstance(receipt, dict)
    if len({raw.get("storeIdentifier"), identity.get("storeIdentifier"),
            admission.get("storeIdentifier")}) != 3:
        verification.fail(f"{label}_store_identifiers_not_distinct")
    if len({raw.get("durableSequence"), identity.get("durableSequence"),
            admission.get("durableSequence")}) != 1:
        verification.fail(f"{label}_store_sequences_mismatch")
    if (
        raw.get("batchKeysSHA256") != identity.get("batchKeysSHA256")
        or raw.get("observedIdentityCount") != identity.get("observedIdentityCount")
    ):
        verification.fail(f"{label}_raw_identity_boundary_mismatch")
    receipt_matches = (
        admission.get("storeIdentifier") == receipt.get("storeIdentifier")
        and admission.get("snapshotSHA256") == receipt.get("snapshotSHA256")
        and admission.get("durableSequence") == receipt.get("durableSequence")
        and admission.get("recordCount") == receipt.get("recordCount")
        and admission.get("byteCount") == receipt.get("byteCount")
        and admission.get("fsyncedAtUnix") == receipt.get("fsyncedAtUnix")
        and raw.get("snapshotSHA256") == receipt.get("rawArchiveSnapshotSHA256")
        and identity.get("snapshotSHA256") == receipt.get("identityIndexSnapshotSHA256")
        and valid_sha(receipt.get("archiveReceiptChainSHA256"))
    )
    if not receipt_matches:
        verification.fail(f"{label}_admission_receipt_mismatch")
    return stores


def stores_at_least(current: dict[str, Any], prior: dict[str, Any]) -> bool:
    for kind in ("raw", "identity", "admission"):
        left = current.get(kind, {})
        right = prior.get(kind, {})
        if (
            left.get("storeIdentifier") != right.get("storeIdentifier")
            or (positive_int(left.get("durableSequence")) or 0)
                < (positive_int(right.get("durableSequence")) or sys.maxsize)
            or (number(left.get("fsyncedAtUnix")) or 0)
                < (number(right.get("fsyncedAtUnix")) or math.inf)
        ):
            return False
    return True


def validate_boundaries(
    verification: Verification, authority: dict[str, Any]
) -> tuple[dict[str, Any], float]:
    attempt = authority.get("attempt", {})
    command_at = number(attempt.get("commandWriteCompletedAtUnix")) or math.inf
    boundaries = authority.get("boundaries")
    if not isinstance(boundaries, list) or not boundaries:
        verification.fail("history_boundaries_missing")
        boundaries = []
    prior_stores: dict[str, Any] | None = None
    prior_ack = command_at
    identifiers: set[str] = set()
    for index, boundary in enumerate(boundaries):
        label = f"boundary_{index}"
        if not isinstance(boundary, dict):
            verification.fail(f"{label}_invalid")
            continue
        identifier = boundary.get("boundaryIdentifier")
        if not isinstance(identifier, str) or not identifier or identifier in identifiers:
            verification.fail(f"{label}_identifier_invalid")
        else:
            identifiers.add(identifier)
        if not valid_sha(boundary.get("historyEndSHA256")) \
                or not valid_sha(boundary.get("expectedACKSHA256")):
            verification.fail(f"{label}_payload_digest_invalid")
        stores = validate_store_pair(verification, boundary.get("stores"), label)
        fsync = number(boundary.get("fsyncedAtUnix"))
        ack = number(boundary.get("ackCompletedAtUnix"))
        if (
            fsync is None or ack is None
            or positive_int(boundary.get("ackAttempt")) is None
            or fsync < command_at or fsync < prior_ack or ack < fsync
        ):
            verification.fail(f"{label}_fsync_ack_order_invalid")
        for kind in ("raw", "identity", "admission"):
            if (number(stores.get(kind, {}).get("fsyncedAtUnix")) or math.inf) > (fsync or -1):
                verification.fail(f"{label}_{kind}_not_fsynced_before_boundary")
        if prior_stores is not None and not stores_at_least(stores, prior_stores):
            verification.fail(f"{label}_store_regression")
        prior_stores = stores
        prior_ack = ack or prior_ack

    terminal = authority.get("historyComplete")
    if not isinstance(terminal, dict):
        verification.fail("history_complete_missing")
        return {}, prior_ack
    terminal_stores = validate_store_pair(
        verification, terminal.get("stores"), "history_complete"
    )
    if (
        not isinstance(terminal.get("completionIdentifier"), str)
        or not terminal["completionIdentifier"]
        or not valid_sha(terminal.get("notificationSHA256"))
        or terminal.get("acknowledgedBoundaryCount") != len(boundaries)
        or number(terminal.get("receivedAtUnix")) is None
        or (number(terminal.get("receivedAtUnix")) or 0) < prior_ack
    ):
        verification.fail("history_complete_terminal_invalid")
    if prior_stores is not None and not stores_at_least(terminal_stores, prior_stores):
        verification.fail("history_complete_store_regression")
    terminal_batch = positive_int(terminal.get("terminalBatchNumber"))
    durable_sequence = positive_int(terminal.get("durableSequence"))
    if (terminal_batch is None) != (durable_sequence is None):
        verification.fail("history_complete_terminal_coordinates_invalid")
    return terminal, prior_ack


def verify_identity_durability(
    verification: Verification, path: Path, terminal_stores: dict[str, Any]
) -> None:
    value, _ = verification.json_file(path, "identity_durability")
    receipt = value.get("receipt")
    admission_receipt = terminal_stores.get("admissionReceipt", {})
    if (
        value.get("version") != 1
        or not isinstance(receipt, dict)
        or receipt.get("raw") != terminal_stores.get("raw")
        or receipt.get("identity") != terminal_stores.get("identity")
        or value.get("chainSHA256") != admission_receipt.get("archiveReceiptChainSHA256")
        or not valid_sha(value.get("previousChainSHA256"))
    ):
        verification.fail("identity_durability_terminal_mismatch")


def verify_admission(
    verification: Verification, path: Path, authority: dict[str, Any],
    terminal_stores: dict[str, Any],
) -> None:
    attempt = authority.get("attempt", {})
    receipt = terminal_stores.get("admissionReceipt", {})
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        row = connection.execute(
            """
            SELECT r.durable_sequence, r.promoted_ordinal, r.raw_digest,
                   r.identity_digest, r.prefix_digest, r.record_count,
                   r.byte_count, a.strap_id, a.durable_ordinal
            FROM history_archive_receipt r
            JOIN history_attempt a ON a.id = r.attempt_id
            WHERE r.chain_digest = ? AND r.attempt_id = ?
            """,
            (receipt.get("archiveReceiptChainSHA256"),
             attempt.get("attemptIdentifier")),
        ).fetchone()
        connection.close()
    except (sqlite3.Error, OSError) as error:
        verification.fail(f"admission_artifact_unreadable_{type(error).__name__}")
        return
    ordinal = receipt.get("durableOrdinal")
    expected_ordinal = -1 if ordinal is None else ordinal
    if row is None or (
        row["durable_sequence"] != receipt.get("durableSequence")
        or row["promoted_ordinal"] != expected_ordinal
        or row["raw_digest"] != receipt.get("rawArchiveSnapshotSHA256")
        or row["identity_digest"] != receipt.get("identityIndexSnapshotSHA256")
        or row["prefix_digest"] != receipt.get("snapshotSHA256")
        or row["record_count"] != receipt.get("recordCount")
        or row["byte_count"] != receipt.get("byteCount")
        or row["strap_id"] != attempt.get("peripheralIdentifier")
        or row["durable_ordinal"] < expected_ordinal
    ):
        verification.fail("admission_artifact_terminal_receipt_mismatch")


def raw_rows(
    verification: Verification, path: Path, raw_seal: dict[str, Any]
) -> tuple[list[tuple[dict[str, Any], int, bytes]], bytes]:
    try:
        data = path.read_bytes()
    except OSError as error:
        verification.fail(f"raw_artifact_unreadable_{type(error).__name__}")
        return [], b""
    if sha256(data) != raw_seal.get("contentSHA256"):
        verification.fail("raw_artifact_sha256_mismatch")
    if len(data) != raw_seal.get("byteCount"):
        verification.fail("raw_artifact_byte_count_mismatch")
    rows: list[tuple[dict[str, Any], int, bytes]] = []
    offset = 0
    timestamps: list[float] = []
    for line in data.splitlines(keepends=True):
        if line.strip():
            try:
                value = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                verification.fail("raw_artifact_jsonl_parse_error")
                value = None
            if isinstance(value, dict):
                rows.append((value, offset, line))
                timestamp = effective_timestamp(value)
                if timestamp is not None:
                    timestamps.append(timestamp)
            else:
                verification.fail("raw_artifact_jsonl_non_object")
        offset += len(line)
    if len(rows) != raw_seal.get("rowCount"):
        verification.fail("raw_artifact_row_count_mismatch")
    if not timestamps:
        verification.fail("raw_artifact_timestamps_missing")
    else:
        if not close(min(timestamps), number(raw_seal.get("firstTimestampUnix"))):
            verification.fail("raw_artifact_first_timestamp_mismatch")
        if not close(max(timestamps), number(raw_seal.get("lastTimestampUnix"))):
            verification.fail("raw_artifact_last_timestamp_mismatch")
    return rows, data


def effective_timestamp(row: dict[str, Any]) -> float | None:
    corrected = number(row.get("clockCorrectedUnix7"))
    raw = number(row.get("unix7"))
    seconds = corrected if corrected is not None and corrected > 0 else raw
    subsecond = number(row.get("subsec11")) or 0
    if seconds is None or seconds <= 0 or subsecond < 0 or subsecond >= 32_768:
        return None
    return seconds + subsecond / 32_768


def close(left: float | None, right: float | None, tolerance: float = 1e-6) -> bool:
    return left is not None and right is not None and abs(left - right) <= tolerance


def verify_coverage(
    verification: Verification, authority: dict[str, Any],
    rows: list[tuple[dict[str, Any], int, bytes]],
    gap_start: float, gap_end: float,
) -> tuple[dict[str, tuple[int, bytes]], dict[str, Any]]:
    proof = authority.get("coverageProof")
    terminal = authority.get("historyComplete", {})
    attempt = authority.get("attempt", {})
    configuration = authority.get("configuration", {})
    if not isinstance(proof, dict):
        verification.fail("coverage_proof_missing")
        return {}, {}
    cadence = positive_int(configuration.get("cadenceSeconds")) or 0
    expected = max(1, math.ceil((gap_end - gap_start) / cadence)) if cadence else 0
    decoder = proof.get("decoderIdentifier")
    decoder_version = positive_int(proof.get("decoderVersion"))
    command_at = number(attempt.get("commandWriteCompletedAtUnix")) or math.inf
    terminal_at = number(terminal.get("receivedAtUnix")) or -math.inf
    covered: set[int] = set()
    identities: dict[str, tuple[int, bytes]] = {}
    for row, offset, line in rows:
        timestamp = effective_timestamp(row)
        observed = number(row.get("_atriaHistoryObservedAtUnix"))
        if (
            timestamp is None or not (gap_start <= timestamp < gap_end)
            or row.get("schema") != decoder_version
            or not isinstance(decoder, str)
            or not is_validated_metric_row(row, {decoder})
        ):
            continue
        if observed is None or observed < command_at or observed > terminal_at:
            verification.fail("coverage_row_not_observed_by_bound_attempt")
            continue
        identity = row.get("_atriaHistoryKey")
        if not isinstance(identity, str) or not identity:
            verification.fail("coverage_row_identity_missing")
            continue
        if identity in identities:
            verification.fail("coverage_raw_duplicate_identity")
            continue
        identities[identity] = (offset, line)
        covered.add(int(math.floor((timestamp - gap_start) / cadence)))
    ordered = sorted(covered)
    bits = bytearray((expected + 7) // 8)
    for index in ordered:
        if 0 <= index < expected:
            bits[index // 8] |= 1 << (index % 8)
    density = math.floor(100 * len(ordered) / expected) if expected else 0
    leading = ordered[0] * cadence if ordered else expected * cadence
    trailing = (expected - 1 - ordered[-1]) * cadence if ordered else expected * cadence
    deltas = [(right - left) * cadence for left, right in zip(ordered, ordered[1:])]
    maximum_gap = max([leading, trailing, *deltas], default=expected * cadence)
    p95_values = sorted(deltas or [max(leading, trailing)])
    p95 = p95_values[max(0, math.ceil(len(p95_values) * 0.95) - 1)]
    timestamp_digest = sha256(",".join(map(str, ordered)).encode())
    terminal_stores = terminal.get("stores", {})
    exact = (
        proof.get("version") == 1
        and normalized_uuid(proof.get("gapIdentifier"))
            == normalized_uuid(authority.get("gap", {}).get("gapIdentifier"))
        and proof.get("attemptIdentifier") == attempt.get("attemptIdentifier")
        and proof.get("transportNonce") == attempt.get("transportNonce")
        and proof.get("transportGeneration") == attempt.get("transportGeneration")
        and proof.get("rawSnapshotSHA256")
            == terminal_stores.get("raw", {}).get("snapshotSHA256")
        and proof.get("identitySnapshotSHA256")
            == terminal_stores.get("identity", {}).get("snapshotSHA256")
        and proof.get("admissionSnapshotSHA256")
            == terminal_stores.get("admission", {}).get("snapshotSHA256")
        and proof.get("expectedBuckets") == expected
        and proof.get("observedBuckets") == len(ordered)
        and proof.get("densityPercent") == density
        and proof.get("maximumGapSeconds") == maximum_gap
        and proof.get("p95GapSeconds") == p95
        and proof.get("coveredBucketBits") == base64.b64encode(bytes(bits)).decode()
        and proof.get("timestampSetSHA256") == timestamp_digest
        and proof.get("firstTimestampUnix") == (
            gap_start + ordered[0] * cadence if ordered else None
        )
        and proof.get("lastTimestampUnix") == (
            gap_start + ordered[-1] * cadence if ordered else None
        )
    )
    if not exact:
        verification.fail("coverage_proof_recomputation_mismatch")
    if (
        density < (positive_int(configuration.get("minimumDensityPercent")) or 101)
        or maximum_gap > (positive_int(configuration.get("maximumGapSeconds")) or -1)
        or p95 > (positive_int(configuration.get("maximumP95GapSeconds")) or -1)
        or not ordered
    ):
        verification.fail("coverage_continuity_below_policy")
    return identities, {
        "expected": expected, "covered": len(ordered), "density": density,
        "maximum_gap": maximum_gap, "p95": p95,
    }


def verify_identity_index(
    verification: Verification, path: Path,
    identities: dict[str, tuple[int, bytes]], raw_path: Path,
) -> None:
    entries: dict[str, dict[str, Any]] = {}
    try:
        lines = path.read_bytes().splitlines()
    except OSError as error:
        verification.fail(f"identity_artifact_unreadable_{type(error).__name__}")
        return
    for line in lines:
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            verification.fail("identity_artifact_parse_error")
            continue
        key = value.get("key") if isinstance(value, dict) else None
        if not isinstance(key, str) or not key or key in entries:
            verification.fail("identity_artifact_duplicate_or_invalid_key")
            continue
        entries[key] = value
    for key, (offset, raw_line) in identities.items():
        entry = entries.get(key)
        if not isinstance(entry, dict):
            verification.fail("coverage_identity_missing_from_index")
            continue
        if (
            entry.get("lineOffset") != offset
            or entry.get("lineLength") != len(raw_line)
            or entry.get("lineCRC32") != zlib.crc32(raw_line)
            or Path(str(entry.get("archivePath", ""))).name != raw_path.name
        ):
            verification.fail("coverage_identity_index_location_mismatch")


def verify_publication(
    verification: Verification, directory: Path, authority: dict[str, Any]
) -> int:
    publication = authority.get("publication")
    terminal = authority.get("historyComplete", {})
    attempt = authority.get("attempt", {})
    if not isinstance(publication, dict):
        verification.fail("publication_checkpoint_missing")
        return 0
    raw_seal = publication.get("rawSeal")
    completion = publication.get("completion")
    if (
        not isinstance(raw_seal, dict)
        or raw_seal.get("drainGeneration") != attempt.get("transportGeneration")
        or not valid_sha(raw_seal.get("contentSHA256"))
        or positive_int(raw_seal.get("rowCount")) is None
        or not isinstance(completion, dict)
        or not valid_sha(completion.get("catalogSnapshotSHA256"))
        or not valid_sha(completion.get("aggregateSnapshotSHA256"))
        or publication.get("status") not in {"completionPublished", "projectionsPublished"}
    ):
        verification.fail("publication_checkpoint_incomplete")
    if (
        terminal.get("terminalBatchNumber") is not None
        and publication.get("terminalBatchNumber") != terminal.get("terminalBatchNumber")
    ) or (
        terminal.get("durableSequence") is not None
        and publication.get("durableSequence") != terminal.get("durableSequence")
    ):
        verification.fail("publication_terminal_coordinates_mismatch")

    status = authority.get("status")
    commit = authority.get("consumerCommit")
    prepared_at = number(authority.get("gapResolutionPreparedAtUnix"))
    resolved_at = number(authority.get("resolvedAtUnix"))
    terminal_at = number(terminal.get("receivedAtUnix"))
    if (
        prepared_at is None or resolved_at is None or terminal_at is None
        or prepared_at < terminal_at or resolved_at < prepared_at
    ):
        verification.fail("gap_resolution_timestamp_order_invalid")
    if status == "gapResolvedConsumersPending":
        if commit is not None:
            verification.fail("pending_authority_has_consumer_commit")
        return 0
    if status != "resolved" or not isinstance(commit, dict):
        verification.fail("authority_not_resolved_or_pending")
        return 0
    receipts = commit.get("receipts")
    if not isinstance(receipts, list) or len(receipts) != 5:
        verification.fail("consumer_commit_not_exact_five")
        return 0
    if receipts != sorted(receipts, key=lambda item: item.get("kind", "")):
        verification.fail("consumer_receipts_not_sorted")
    if commit.get("receiptSetSHA256") != sha256(canonical(receipts)):
        verification.fail("consumer_receipt_set_sha256_mismatch")
    expected_kinds = set(REQUIRED_CONSUMERS)
    if {item.get("kind") for item in receipts if isinstance(item, dict)} != expected_kinds:
        verification.fail("consumer_kinds_mismatch")

    source = {
        "chunkID": publication.get("chunkID"),
        "rawSHA256": raw_seal.get("contentSHA256") if isinstance(raw_seal, dict) else None,
        "firstTimestamp": None,
        "lastTimestamp": None,
    }
    actual_entries: list[dict[str, str]] = []
    artifact_shas: list[str] = []
    for receipt in receipts:
        if not isinstance(receipt, dict):
            continue
        kind = receipt.get("kind")
        filename = receipt.get("commitIdentifier")
        if (
            kind not in REQUIRED_CONSUMERS
            or not isinstance(filename, str)
            or Path(filename).name != filename
        ):
            verification.fail("consumer_receipt_identity_invalid")
            continue
        receipt_path = directory / filename
        try:
            receipt_data = receipt_path.read_bytes()
            document = json.loads(receipt_data)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            verification.fail(f"consumer_receipt_unreadable_{kind}")
            continue
        if sha256(receipt_data) != receipt.get("receiptSHA256"):
            verification.fail(f"consumer_receipt_sha256_mismatch_{kind}")
        receipt_source = document.get("source") if isinstance(document, dict) else None
        if not isinstance(receipt_source, dict):
            verification.fail(f"consumer_receipt_source_missing_{kind}")
            continue
        if source["firstTimestamp"] is None:
            source["firstTimestamp"] = receipt_source.get("firstTimestamp")
            source["lastTimestamp"] = receipt_source.get("lastTimestamp")
        if (
            receipt_source != source
            or document.get("kind") != REQUIRED_CONSUMERS[kind]
            or document.get("artifactSHA256") != receipt.get("artifactSHA256")
            or receipt.get("gapIdentifier") != authority.get("gap", {}).get("gapIdentifier")
            or receipt.get("attemptIdentifier") != attempt.get("attemptIdentifier")
            or receipt.get("completionIdentifier") != terminal.get("completionIdentifier")
            or receipt.get("sourceRawSnapshotSHA256")
                != terminal.get("stores", {}).get("raw", {}).get("snapshotSHA256")
            or receipt.get("sourceIdentitySnapshotSHA256")
                != terminal.get("stores", {}).get("identity", {}).get("snapshotSHA256")
            or receipt.get("sourceAdmissionSnapshotSHA256")
                != terminal.get("stores", {}).get("admission", {}).get("snapshotSHA256")
            or not close(iso_unix(document.get("settledAt")),
                         number(receipt.get("committedAtUnix")), 0.001)
        ):
            verification.fail(f"consumer_receipt_authority_mismatch_{kind}")
        artifact_name = document.get("artifactFilename")
        artifact_path = directory / str(artifact_name)
        try:
            artifact_data = artifact_path.read_bytes()
        except OSError:
            verification.fail(f"consumer_artifact_missing_{kind}")
            continue
        if (
            Path(str(artifact_name)).name != artifact_name
            or len(artifact_data) != document.get("artifactByteCount")
            or sha256(artifact_data) != document.get("artifactSHA256")
        ):
            verification.fail(f"consumer_artifact_digest_mismatch_{kind}")
        artifact_shas.append(receipt.get("artifactSHA256", ""))
        actual_entries.append({
            "kind": REQUIRED_CONSUMERS[kind],
            "receiptFilename": filename,
            "receiptSHA256": receipt.get("receiptSHA256", ""),
        })

    projection = publication.get("projections")
    if (
        publication.get("status") != "projectionsPublished"
        or not isinstance(projection, dict)
        or projection.get("receiptCount") != 5
        or sorted(projection.get("artifactSHA256s", [])) != sorted(artifact_shas)
    ):
        verification.fail("publication_projection_receipts_mismatch")
    source_key = sha256(f"{source['chunkID']}|{source['rawSHA256']}".encode())
    pointer_path = directory / f"consumer-set-current-{source_key}.json"
    pointer, _ = verification.json_file(pointer_path, "consumer_current_set")
    set_filename = pointer.get("setFilename")
    if (
        pointer.get("version") != 1 or pointer.get("source") != source
        or not isinstance(set_filename, str) or Path(set_filename).name != set_filename
        or not valid_sha(pointer.get("setSHA256"))
    ):
        verification.fail("consumer_current_set_pointer_invalid")
        return len(receipts)
    set_path = directory / set_filename
    try:
        set_data = set_path.read_bytes()
        receipt_set = json.loads(set_data)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        verification.fail("consumer_current_set_unreadable")
        return len(receipts)
    if (
        sha256(set_data) != pointer.get("setSHA256")
        or receipt_set.get("version") != 1
        or receipt_set.get("source") != source
        or receipt_set.get("entries") != sorted(actual_entries, key=lambda item: item["kind"])
    ):
        verification.fail("consumer_current_set_mismatch")
    return len(receipts)


def verify_anchor(
    verification: Verification, path: Path, terminal_at: float,
    captured_at: float, label: str, maximum_age: float,
) -> float | None:
    value, _ = verification.json_file(path, label)
    accepted = number(value.get("acceptedUnix"))
    if (
        value.get("version") != 1 or accepted is None
        or accepted <= terminal_at or accepted > captured_at + 5
        or captured_at - accepted > maximum_age
    ):
        verification.fail(f"{label}_not_fresh_after_terminal")
    return accepted


def immutable_authority_core(authority: dict[str, Any]) -> dict[str, Any]:
    publication = authority.get("publication", {})
    return {
        "version": authority.get("version"),
        "authorityIdentifier": authority.get("authorityIdentifier"),
        "createdAtUnix": authority.get("createdAtUnix"),
        "gap": authority.get("gap"),
        "attempt": authority.get("attempt"),
        "configuration": authority.get("configuration"),
        "boundaries": authority.get("boundaries"),
        "historyComplete": authority.get("historyComplete"),
        "coverageProof": authority.get("coverageProof"),
        "publicationCore": {
            key: publication.get(key)
            for key in (
                "chunkID", "terminalBatchNumber", "durableSequence",
                "completedAtUnix", "rawSeal",
            )
        },
        "gapResolutionPreparedAtUnix": authority.get("gapResolutionPreparedAtUnix"),
        "resolvedAtUnix": authority.get("resolvedAtUnix"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gap-identifier", required=True)
    parser.add_argument("--requested-start-unix", required=True, type=float)
    parser.add_argument("--requested-end-unix", required=True, type=float)
    parser.add_argument("--pre-ledger", required=True, type=Path)
    parser.add_argument("--mid-ledger", required=True, type=Path)
    parser.add_argument("--post-ledger", required=True, type=Path)
    parser.add_argument("--authority", required=True, type=Path)
    parser.add_argument("--live-anchor", required=True, type=Path)
    parser.add_argument("--raw-artifact", required=True, type=Path)
    parser.add_argument("--identity-artifact", required=True, type=Path)
    parser.add_argument("--identity-durability-artifact", required=True, type=Path)
    parser.add_argument("--admission-artifact", required=True, type=Path)
    parser.add_argument("--publication-directory", required=True, type=Path)
    parser.add_argument("--post-captured-at-unix", required=True, type=float)
    parser.add_argument("--maximum-live-age-seconds", type=float, default=120)
    parser.add_argument("--post-relaunch-ledger", type=Path)
    parser.add_argument("--post-relaunch-authority", type=Path)
    parser.add_argument("--post-relaunch-live-anchor", type=Path)
    parser.add_argument("--post-relaunch-captured-at-unix", type=float)
    args = parser.parse_args()

    verification = Verification()
    gap_id = normalized_uuid(args.gap_identifier)
    if gap_id is None:
        verification.fail("requested_gap_uuid_invalid")
        gap_id = ""
    start = args.requested_start_unix
    end = args.requested_end_unix
    if not all(math.isfinite(value) for value in (start, end)) or end <= start:
        verification.fail("requested_gap_bounds_invalid")
    if (
        not math.isfinite(args.maximum_live_age_seconds)
        or args.maximum_live_age_seconds <= 0
        or args.maximum_live_age_seconds > 600
    ):
        verification.fail("maximum_live_age_seconds_invalid")

    pre, _ = ledger(verification, args.pre_ledger, "pre_ledger")
    mid, mid_raw = ledger(verification, args.mid_ledger, "mid_ledger")
    post, _ = ledger(verification, args.post_ledger, "post_ledger")
    if ledger_windows(pre, gap_id):
        verification.fail("gap_uuid_existed_before_controlled_outage")
    mid_matches = ledger_windows(mid, gap_id)
    if len(mid_matches) != 1:
        verification.fail(f"mid_ledger_gap_match_count_{len(mid_matches)}")
        window = {}
    else:
        window = mid_matches[0]
        window_start, window_end = window_bounds(window)
        if not close(window_start, start, 0.001) or not close(window_end, end, 0.001):
            verification.fail("mid_ledger_gap_bounds_mismatch")
        if not expected_window_is_contiguous(window, start, end):
            verification.fail("mid_ledger_expected_interval_not_contiguous")
    if ledger_windows(post, gap_id):
        verification.fail("post_ledger_gap_cas_absent")
    mid_generation = positive_int(mid.get("generation"))
    post_generation = positive_int(post.get("generation"))
    if (
        positive_int(pre.get("generation")) is None
        or mid_generation is None or post_generation is None
        or mid_generation <= pre.get("generation", 0)
        or post_generation <= mid_generation
    ):
        verification.fail("ledger_generation_order_invalid")

    envelope, _ = verification.json_file(args.authority, "authority")
    authority = envelope.get("authority")
    if envelope.get("version") != 1 or not isinstance(authority, dict):
        verification.fail("authority_envelope_invalid")
        authority = {}
    gap = authority.get("gap") if isinstance(authority.get("gap"), dict) else {}
    attempt = authority.get("attempt") if isinstance(authority.get("attempt"), dict) else {}
    if (
        authority.get("version") != 1
        or normalized_uuid(gap.get("gapIdentifier")) != gap_id
        or gap.get("gapLedgerGeneration") != mid_generation
        or gap.get("gapLedgerSnapshotSHA256") != sha256(mid_raw)
        or not close(number(gap.get("startUnix")), start, 0.001)
        or not close(number(gap.get("endUnix")), end, 0.001)
        or gap.get("pending") is not True
    ):
        verification.fail("authority_gap_ledger_binding_mismatch")
    if (
        positive_int(attempt.get("attemptNumber")) is None
        or positive_int(attempt.get("transportGeneration")) is None
        or not valid_sha(attempt.get("fullDrainCommandSHA256"))
        or not all(isinstance(attempt.get(key), str) and attempt.get(key) for key in (
            "attemptIdentifier", "peripheralIdentifier", "strapIdentity", "transportNonce"
        ))
    ):
        verification.fail("authority_attempt_invalid")
    validate_transport(verification, attempt, end)
    terminal, _ = validate_boundaries(verification, authority)
    terminal_stores = terminal.get("stores") if isinstance(terminal.get("stores"), dict) else {}
    verify_identity_durability(
        verification, args.identity_durability_artifact, terminal_stores
    )
    verify_admission(verification, args.admission_artifact, authority, terminal_stores)

    publication = authority.get("publication") if isinstance(
        authority.get("publication"), dict
    ) else {}
    raw_seal = publication.get("rawSeal") if isinstance(
        publication.get("rawSeal"), dict
    ) else {}
    rows, _ = raw_rows(verification, args.raw_artifact, raw_seal)
    identities, coverage = verify_coverage(verification, authority, rows, start, end)
    verify_identity_index(
        verification, args.identity_artifact, identities, args.raw_artifact
    )
    receipt_count = verify_publication(
        verification, args.publication_directory, authority
    )
    terminal_at = number(terminal.get("receivedAtUnix")) or math.inf
    anchor = verify_anchor(
        verification, args.live_anchor, terminal_at, args.post_captured_at_unix,
        "live_anchor", args.maximum_live_age_seconds,
    )

    relaunch_values = (
        args.post_relaunch_ledger, args.post_relaunch_authority,
        args.post_relaunch_live_anchor, args.post_relaunch_captured_at_unix,
    )
    if any(value is not None for value in relaunch_values):
        if not all(value is not None for value in relaunch_values):
            verification.fail("post_relaunch_snapshot_incomplete")
        else:
            relaunch_ledger, _ = ledger(
                verification, args.post_relaunch_ledger, "post_relaunch_ledger"
            )
            if ledger_windows(relaunch_ledger, gap_id):
                verification.fail("post_relaunch_gap_reappeared")
            if (positive_int(relaunch_ledger.get("generation")) or 0) < (post_generation or 0):
                verification.fail("post_relaunch_ledger_generation_regressed")
            relaunch_envelope, _ = verification.json_file(
                args.post_relaunch_authority, "post_relaunch_authority"
            )
            relaunch_authority = relaunch_envelope.get("authority")
            if (
                not isinstance(relaunch_authority, dict)
                or immutable_authority_core(relaunch_authority)
                    != immutable_authority_core(authority)
            ):
                verification.fail("post_relaunch_authority_core_mutated")
            status_rank = {"gapResolvedConsumersPending": 0, "resolved": 1}
            if (
                isinstance(relaunch_authority, dict)
                and status_rank.get(relaunch_authority.get("status"), -1)
                    < status_rank.get(authority.get("status"), -1)
            ):
                verification.fail("post_relaunch_authority_status_regressed")
            relaunch_anchor = verify_anchor(
                verification, args.post_relaunch_live_anchor, terminal_at,
                args.post_relaunch_captured_at_unix, "post_relaunch_live_anchor",
                args.maximum_live_age_seconds,
            )
            if anchor is not None and relaunch_anchor is not None and relaunch_anchor < anchor:
                verification.fail("post_relaunch_live_anchor_regressed")

    print(f"gate2_release_artifact_status={'pass' if not verification.blockers else 'fail'}")
    print(f"gap_identifier={gap_id or 'invalid'}")
    print(f"gap_start_unix={start:g}")
    print(f"gap_end_unix={end:g}")
    print(f"gap_ledger_generation={mid_generation or 0}")
    print(f"transport_generation={attempt.get('transportGeneration', 0)}")
    print(f"coverage_expected_seconds={coverage.get('expected', 0)}")
    print(f"coverage_observed_seconds={coverage.get('covered', 0)}")
    print(f"coverage_percent={coverage.get('density', 0)}")
    print(f"coverage_maximum_gap_seconds={coverage.get('maximum_gap', 0)}")
    print(f"coverage_p95_gap_seconds={coverage.get('p95', 0)}")
    print(f"consumer_receipts={receipt_count}")
    print(f"live_anchor_unix={anchor or 0:g}")
    print("blockers=" + (
        ",".join(verification.blockers) if verification.blockers else "none"
    ))
    return 0 if not verification.blockers else 1


if __name__ == "__main__":
    raise SystemExit(main())
