#!/usr/bin/env python3
"""Verify one controlled, interrupted, then resumed WHOOP 4 history recovery.

This verifier is deliberately artifact-bound. Console markers prove transport
ordering; they do not choose the local gap. The canonical gap ledger and the
fsynced full-drain authority bind the controlled wall-clock interval to its
UUID, generation, snapshot digest, expected-second mask, coverage proof, CAS
retirement, and five consumer receipts.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_hist1_acceptance import (  # noqa: E402
    archive_files,
    effective_timestamp,
    is_validated_metric_row,
    validated_layouts,
)
from verify_whoop4_exact_history_transaction import events, integer, verify  # noqa: E402


AUTHORITY_FILE = "historical-full-drain-coverage-authority-v1.json"
LEDGER_FILE = "historical-gap-ledger-v2.json"
REQUIRED_CONSUMERS = {"activity", "daily_metrics", "sleep", "steps", "workout"}


def read_json(path: Path, blockers: list[str], label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        blockers.append(f"{label}_unreadable:{type(error).__name__}")
        return {}
    if not isinstance(value, dict):
        blockers.append(f"{label}_not_object")
        return {}
    return value


def find_file(root: Path, name: str, blockers: list[str], label: str) -> Path | None:
    matches = sorted(path for path in root.rglob(name) if path.is_file()) if root.is_dir() else []
    if len(matches) != 1:
        blockers.append(f"{label}_file_count_{len(matches)}")
        return None
    return matches[0]


def finite_number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    return result if math.isfinite(result) else None


def positive_int(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return None
    return value


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def valid_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def ledger(root: Path, blockers: list[str], label: str) -> tuple[dict[str, Any], str]:
    path = find_file(root / "historical-gap-ledger-v2", LEDGER_FILE, blockers, label)
    if path is None:
        return {}, "missing"
    raw = path.read_bytes()
    document = read_json(path, blockers, label)
    if document.get("version") != 2 or document.get("state") != "valid":
        blockers.append(f"{label}_not_canonical_valid_v2")
    # Swift rejects semantically equivalent but non-canonical bytes. Matching
    # its sorted-key, compact JSON encoding prevents a hand-written snapshot
    # from borrowing a real authority digest.
    try:
        canonical = json.dumps(
            document, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
    except (TypeError, ValueError):
        canonical = b""
    if canonical != raw:
        blockers.append(f"{label}_not_canonical_bytes")
    return document, sha256_bytes(raw)


def authority(root: Path, blockers: list[str], label: str) -> dict[str, Any]:
    path = find_file(root / "historical-full-drain-authority-v1", AUTHORITY_FILE,
                     blockers, label)
    if path is None:
        return {}
    document = read_json(path, blockers, label)
    value = document.get("authority")
    if value is None and "gap" in document:
        value = document
    if not isinstance(value, dict):
        blockers.append(f"{label}_authority_missing")
        return {}
    return value


def matching_window(
    document: dict[str, Any], start: float, end: float, tolerance: float,
    blockers: list[str], label: str,
) -> dict[str, Any]:
    windows = document.get("windows")
    if not isinstance(windows, list):
        blockers.append(f"{label}_windows_missing")
        return {}
    candidates = []
    for window in windows:
        if not isinstance(window, dict):
            continue
        window_start = finite_number(window.get("start"))
        window_end = finite_number(window.get("end"))
        if window_start is None or window_end is None:
            continue
        # Foundation Date's default JSON representation is seconds since the
        # 2001 Apple epoch. Physical ledgers may instead be decoded/exported as
        # Unix seconds by support tooling.
        if window_start < 1_000_000_000:
            window_start += 978_307_200
        if window_end < 1_000_000_000:
            window_end += 978_307_200
        if abs(window_start - start) <= tolerance and abs(window_end - end) <= tolerance:
            copy = dict(window)
            copy["_startUnix"] = window_start
            copy["_endUnix"] = window_end
            candidates.append(copy)
    if len(candidates) != 1:
        blockers.append(f"{label}_controlled_gap_match_count_{len(candidates)}")
        return {}
    return candidates[0]


def expected_seconds(window: dict[str, Any], blockers: list[str]) -> tuple[set[int], str]:
    start = finite_number(window.get("_startUnix"))
    end = finite_number(window.get("_endUnix"))
    if start is None or end is None or end <= start:
        blockers.append("controlled_gap_bounds_invalid")
        return set(), "missing"
    count = max(1, int(math.ceil(end - start)))
    encoded = window.get("expectedSecondBitsBase64")
    if encoded is None:
        indexes = set(range(count))
        mask = bytearray((count + 7) // 8)
        for second in indexes:
            mask[second // 8] |= 1 << (second % 8)
        return indexes, sha256_bytes(bytes(mask))
    if not isinstance(encoded, str):
        blockers.append("expected_mask_not_base64_string")
        return set(), "missing"
    try:
        mask = base64.b64decode(encoded, validate=True)
    except ValueError:
        blockers.append("expected_mask_invalid_base64")
        return set(), "missing"
    indexes = {
        second for second in range(count)
        if second // 8 < len(mask) and mask[second // 8] & (1 << (second % 8))
    }
    if not indexes:
        blockers.append("expected_mask_empty")
    return indexes, sha256_bytes(mask)


def transport_valid(attempt: dict[str, Any], blockers: list[str], label: str) -> None:
    transport = attempt.get("transportAuthority")
    if not isinstance(transport, dict):
        blockers.append(f"{label}_transport_authority_missing")
        return
    numeric = {
        key: finite_number(transport.get(key))
        for key in (
            "clockCommandRequestedAtUnix", "clockWriteCompletedAtUnix",
            "clockResponseReceivedAtUnix", "deviceClockUnix", "clockWallUnix",
            "fullDrainCommandRequestedAtUnix", "fullDrainWriteCompletedAtUnix",
            "historyStartReceivedAtUnix",
        )
    }
    if any(value is None for value in numeric.values()):
        blockers.append(f"{label}_transport_times_invalid")
        return
    command_sequence = transport.get("clockCommandSequence")
    response_sequence = transport.get("clockResponseSequence")
    full_sequence = transport.get("fullDrainCommandSequence")
    if command_sequence != response_sequence or full_sequence == command_sequence:
        blockers.append(f"{label}_transport_sequence_invalid")
    n = numeric
    if abs(n["clockResponseReceivedAtUnix"] - n["clockWallUnix"]) > 2:
        blockers.append(f"{label}_clock_response_not_fresh")
    if abs(n["clockWallUnix"] - n["deviceClockUnix"]) > 24 * 60 * 60:
        blockers.append(f"{label}_clock_drift_over_24h")
    ordered = (
        n["clockResponseReceivedAtUnix"] >= n["clockCommandRequestedAtUnix"]
        and n["clockWriteCompletedAtUnix"] >= n["clockCommandRequestedAtUnix"]
        and n["fullDrainCommandRequestedAtUnix"] >= n["clockWriteCompletedAtUnix"]
        and n["fullDrainCommandRequestedAtUnix"] >= n["clockResponseReceivedAtUnix"]
        and n["fullDrainWriteCompletedAtUnix"] >= n["fullDrainCommandRequestedAtUnix"]
        and n["historyStartReceivedAtUnix"] >= n["fullDrainCommandRequestedAtUnix"]
    )
    if not ordered:
        blockers.append(f"{label}_transport_event_order_invalid")


def archive_coverage(
    root: Path, layouts: set[str], start: float, expected: set[int],
    blockers: list[str],
) -> tuple[dict[str, Any], set[str]]:
    seen: list[tuple[int, str]] = []
    parse_errors = 0
    for path in archive_files(root):
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    parse_errors += 1
                    continue
                if not isinstance(row, dict) or not is_validated_metric_row(row, layouts):
                    continue
                timestamp = effective_timestamp(row)
                identity = row.get("_atriaHistoryKey")
                if timestamp is None or not isinstance(identity, str) or not identity:
                    continue
                second = int(math.floor(timestamp - start))
                if second in expected:
                    seen.append((second, identity))
    if parse_errors:
        blockers.append("post_archive_parse_errors")
    identities = [identity for _, identity in seen]
    if len(identities) != len(set(identities)):
        blockers.append("post_archive_duplicate_gap_identities")
    covered = {second for second, _ in seen}
    density = int(math.floor(100 * len(covered) / len(expected))) if expected else 0
    ordered = sorted(covered)
    internal_deltas = [right - left for left, right in zip(ordered, ordered[1:])]
    leading = ordered[0] if ordered else len(expected)
    trailing = (max(expected) - ordered[-1]) if ordered and expected else len(expected)
    maximum_gap = max(leading, trailing, max(internal_deltas, default=0))
    percentile_values = internal_deltas if internal_deltas else [max(leading, trailing)]
    sorted_deltas = sorted(percentile_values)
    p95 = sorted_deltas[max(0, math.ceil(len(sorted_deltas) * 0.95) - 1)]
    bits = bytearray((len(expected) + 7) // 8)
    for second in ordered:
        bits[second // 8] |= 1 << (second % 8)
    timestamp_set_sha256 = sha256_bytes(",".join(map(str, ordered)).encode("utf-8"))
    if density < 90:
        blockers.append("exact_gap_density_below_90_percent")
    if maximum_gap > 3:
        blockers.append("exact_gap_maximum_gap_over_3s")
    if p95 > 1:
        blockers.append("exact_gap_p95_gap_over_1s")
    if not seen:
        blockers.append("strap_returned_zero_metric_rows")
    return {
        "rows": len(seen), "covered": len(covered), "expected": len(expected),
        "density": density, "maximum_gap": maximum_gap, "p95_gap": p95,
        "duplicates": len(identities) - len(set(identities)),
        "covered_bits": bytes(bits), "timestamp_set_sha256": timestamp_set_sha256,
        "first_timestamp": start + ordered[0] if ordered else None,
        "last_timestamp": start + ordered[-1] if ordered else None,
    }, set(identities)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--marker", required=True, type=Path)
    parser.add_argument("--pre-gap-full", required=True, type=Path)
    parser.add_argument("--mid-drain-full", required=True, type=Path)
    parser.add_argument("--interrupt-full", required=True, type=Path)
    parser.add_argument("--post-resume-full", required=True, type=Path)
    parser.add_argument("--interrupted-log", required=True, type=Path)
    parser.add_argument("--resumed-log", required=True, type=Path)
    parser.add_argument(
        "--bound-tolerance-seconds", type=float, default=45.0,
        help=(
            "Maximum manual-action/command edge delay. The canonical ledger "
            "still owns the exact recovery interval and must contain one new UUID."
        ),
    )
    args = parser.parse_args()

    blockers: list[str] = []
    if (
        not math.isfinite(args.bound_tolerance_seconds)
        or args.bound_tolerance_seconds < 0
        or args.bound_tolerance_seconds > 60
    ):
        blockers.append("bound_tolerance_invalid")
    marker = read_json(args.marker, blockers, "marker")
    start = finite_number(marker.get("gapStartUnix"))
    end = finite_number(marker.get("reconnectUnix"))
    if start is None or end is None or end <= start:
        blockers.append("marker_bounds_invalid")
        start, end = 1.0, 2.0
    duration = end - start
    if duration < 120 or duration > 600:
        blockers.append("controlled_gap_not_2_to_10_minutes")

    phase_evidence = (
        (args.pre_gap_full, "prepare", "pre_gap_full", False),
        (args.pre_gap_full.parent / "pre-gap-runtime", "prepare", "pre_gap_runtime", True),
        (args.mid_drain_full, "post-reconnect-drain", "mid_drain_full", False),
        (args.mid_drain_full.parent / "mid-drain-runtime", "post-reconnect-drain",
         "mid_drain_runtime", True),
        (args.interrupt_full, "interrupt", "interrupt_full", False),
        (args.interrupt_full.parent / "interrupt-runtime", "interrupt",
         "interrupt_runtime", True),
        (args.post_resume_full, "resume-final", "post_resume_full", False),
        (args.post_resume_full.parent / "post-resume-runtime", "resume-final",
         "post_resume_runtime", True),
    )
    for directory, phase, label, require_process in phase_evidence:
        require_phase_evidence(directory, phase, blockers, label, require_process)

    pre_ledger, _ = ledger(args.pre_gap_full, blockers, "pre_ledger")
    pre_window_ids = {
        str(item.get("id", "")).lower()
        for item in pre_ledger.get("windows", [])
        if isinstance(item, dict) and item.get("id")
    }
    mid_ledger, mid_digest = ledger(args.mid_drain_full, blockers, "mid_ledger")
    mid_generation = positive_int(mid_ledger.get("generation"))
    window = matching_window(mid_ledger, start, end, args.bound_tolerance_seconds,
                             blockers, "mid_ledger")
    expected, expected_digest = expected_seconds(window, blockers)
    if expected != set(range(max(expected, default=-1) + 1)):
        blockers.append("controlled_gap_expected_mask_not_contiguous")
    gap_id = str(window.get("id", "")).lower()
    if not gap_id:
        blockers.append("controlled_gap_uuid_missing")
    elif gap_id in pre_window_ids:
        blockers.append("controlled_gap_uuid_existed_before_manual_gap")

    interrupted_authority = authority(args.interrupt_full, blockers, "interrupt")
    final_authority = authority(args.post_resume_full, blockers, "post")
    for label, value in (("interrupt", interrupted_authority), ("post", final_authority)):
        gap = value.get("gap") if isinstance(value.get("gap"), dict) else {}
        if str(gap.get("gapIdentifier", "")).lower() != gap_id:
            blockers.append(f"{label}_authority_gap_uuid_mismatch")
        if gap.get("gapLedgerGeneration") != mid_generation:
            blockers.append(f"{label}_authority_ledger_generation_mismatch")
        if gap.get("gapLedgerSnapshotSHA256") != mid_digest:
            blockers.append(f"{label}_authority_ledger_digest_mismatch")
        if abs((finite_number(gap.get("startUnix")) or 0) - window.get("_startUnix", 0)) > 0.001:
            blockers.append(f"{label}_authority_start_mismatch")
        if abs((finite_number(gap.get("endUnix")) or 0) - window.get("_endUnix", 0)) > 0.001:
            blockers.append(f"{label}_authority_end_mismatch")
        transport_valid(value.get("attempt") if isinstance(value.get("attempt"), dict) else {},
                        blockers, label)

    interrupt_text = args.interrupted_log.read_text(encoding="utf-8", errors="replace") \
        if args.interrupted_log.is_file() else ""
    resume_text = args.resumed_log.read_text(encoding="utf-8", errors="replace") \
        if args.resumed_log.is_file() else ""
    if not interrupt_text:
        blockers.append("interrupted_log_missing_or_empty")
    if not resume_text:
        blockers.append("resumed_log_missing_or_empty")
    interrupt_armed = [event for event in events(interrupt_text,
        "ATRIADBG historical_full_drain_authority")
        if event.fields.get("status") == "armed" and event.fields.get("gap", "").lower() == gap_id]
    interrupt_generation = integer(interrupt_armed[-1], "generation") if interrupt_armed else None
    if interrupt_generation is None:
        blockers.append("interrupted_attempt_authority_missing")
    interrupt_durable = [event for event in events(interrupt_text, "ATRIADBG historyDrain")
        if event.fields.get("status") == "durable"
        and integer(event, "generation") == interrupt_generation]
    interrupt_accepted = [event for event in events(interrupt_text, "ATRIADBG historyAck")
        if event.fields.get("status") in {"accepted", "confirmed"}
        and integer(event, "generation") == interrupt_generation]
    interrupt_terminal = [event for event in events(interrupt_text, "ATRIADBG historyTerminal")
        if integer(event, "generation") == interrupt_generation]
    if not interrupt_durable:
        blockers.append("interrupted_attempt_has_no_durable_batch")
    if not interrupt_accepted:
        blockers.append("interrupted_attempt_has_no_accepted_ack")
    if interrupt_terminal:
        blockers.append("interrupted_attempt_already_terminal")
    if "gap_retained=1" not in interrupt_text:
        blockers.append("interrupted_attempt_gap_retention_unproven")

    combined = interrupt_text + "\n" + resume_text
    late_interrupted_terminal = [
        event for event in events(combined, "ATRIADBG historyTerminal")
        if integer(event, "generation") == interrupt_generation
    ]
    if late_interrupted_terminal:
        blockers.append("interrupted_generation_became_terminal_after_capture")
    transaction_blockers, details = verify(combined, start, end)
    blockers.extend(f"transaction:{item}" for item in transaction_blockers)
    resume_generation = details.get("transport_generation")
    if interrupt_generation is not None and resume_generation == interrupt_generation:
        blockers.append("resume_reused_interrupted_transport_generation")
    if str(details.get("gap_identifier", "")).lower() != gap_id:
        blockers.append("resume_transaction_gap_uuid_mismatch")

    post_fields = read_key_values(args.post_resume_full / "pull-summary.txt")
    layouts = validated_layouts(post_fields)
    if not layouts:
        blockers.append("post_validated_layouts_missing")
    if post_fields.get("historical_archive_identity_duplicate_keys") != "0":
        blockers.append("post_identity_index_duplicates_or_unverified")
    coverage, _ = archive_coverage(args.post_resume_full, layouts,
                                   window.get("_startUnix", start), expected, blockers)
    proof = final_authority.get("coverageProof")
    final_attempt = final_authority.get("attempt") \
        if isinstance(final_authority.get("attempt"), dict) else {}
    terminal = final_authority.get("historyComplete") \
        if isinstance(final_authority.get("historyComplete"), dict) else {}
    stores = terminal.get("stores") if isinstance(terminal.get("stores"), dict) else {}
    raw_seal = stores.get("raw") if isinstance(stores.get("raw"), dict) else {}
    identity_seal = stores.get("identity") if isinstance(stores.get("identity"), dict) else {}
    admission_seal = stores.get("admission") if isinstance(stores.get("admission"), dict) else {}
    seals = (raw_seal, identity_seal, admission_seal)
    if not terminal.get("completionIdentifier") or any(
        not valid_sha256(seal.get("snapshotSHA256"))
        or positive_int(seal.get("durableSequence")) is None
        or not seal.get("storeIdentifier")
        for seal in seals
    ):
        blockers.append("history_complete_store_seals_invalid")
    if len({seal.get("storeIdentifier") for seal in seals}) != 3:
        blockers.append("history_complete_store_identifiers_not_distinct")
    if len({seal.get("durableSequence") for seal in seals}) != 1:
        blockers.append("history_complete_store_sequences_mismatch")
    if raw_seal.get("batchKeysSHA256") != identity_seal.get("batchKeysSHA256"):
        blockers.append("history_complete_raw_identity_batch_keys_mismatch")
    if raw_seal.get("observedIdentityCount") != identity_seal.get("observedIdentityCount"):
        blockers.append("history_complete_raw_identity_counts_mismatch")
    if not isinstance(proof, dict):
        blockers.append("final_coverage_proof_missing")
    else:
        if proof.get("gapIdentifier", "").lower() != gap_id:
            blockers.append("final_coverage_proof_gap_mismatch")
        if proof.get("densityPercent") != coverage["density"]:
            blockers.append("final_coverage_density_mismatch")
        if proof.get("maximumGapSeconds") != coverage["maximum_gap"]:
            blockers.append("final_coverage_max_gap_mismatch")
        if proof.get("p95GapSeconds") != coverage["p95_gap"]:
            blockers.append("final_coverage_p95_gap_mismatch")
        if proof.get("observedBuckets") != coverage["covered"]:
            blockers.append("final_coverage_observed_bucket_count_mismatch")
        if proof.get("expectedBuckets") != coverage["expected"]:
            blockers.append("final_coverage_expected_bucket_count_mismatch")
        encoded_bits = proof.get("coveredBucketBits")
        try:
            proof_bits = base64.b64decode(encoded_bits, validate=True) \
                if isinstance(encoded_bits, str) else b""
        except ValueError:
            proof_bits = b""
        if proof_bits != coverage["covered_bits"]:
            blockers.append("final_coverage_bitset_mismatch")
        if proof.get("timestampSetSHA256") != coverage["timestamp_set_sha256"]:
            blockers.append("final_coverage_timestamp_set_digest_mismatch")
        if proof.get("firstTimestampUnix") != coverage["first_timestamp"]:
            blockers.append("final_coverage_first_timestamp_mismatch")
        if proof.get("lastTimestampUnix") != coverage["last_timestamp"]:
            blockers.append("final_coverage_last_timestamp_mismatch")
        if proof.get("attemptIdentifier") != final_attempt.get("attemptIdentifier"):
            blockers.append("final_coverage_attempt_identifier_mismatch")
        if proof.get("transportNonce") != final_attempt.get("transportNonce"):
            blockers.append("final_coverage_transport_nonce_mismatch")
        if proof.get("transportGeneration") != final_attempt.get("transportGeneration"):
            blockers.append("final_coverage_transport_generation_mismatch")
        for proof_key, seal in (
            ("rawSnapshotSHA256", raw_seal),
            ("identitySnapshotSHA256", identity_seal),
            ("admissionSnapshotSHA256", admission_seal),
        ):
            if proof.get(proof_key) != seal.get("snapshotSHA256") \
                    or not valid_sha256(proof.get(proof_key)):
                blockers.append(f"final_coverage_{proof_key}_seal_mismatch")

    commit = final_authority.get("consumerCommit")
    receipts = commit.get("receipts") if isinstance(commit, dict) else None
    kinds = {receipt.get("kind") for receipt in receipts if isinstance(receipt, dict)} \
        if isinstance(receipts, list) else set()
    if kinds != REQUIRED_CONSUMERS or len(receipts or []) != 5:
        blockers.append("final_consumer_receipts_not_exact_five")
    if isinstance(receipts, list):
        for receipt in receipts:
            if not isinstance(receipt, dict) or any(
                not valid_sha256(receipt.get(key)) for key in (
                    "receiptSHA256", "artifactSHA256", "sourceRawSnapshotSHA256",
                    "sourceIdentitySnapshotSHA256", "sourceAdmissionSnapshotSHA256",
                )
            ):
                blockers.append("final_consumer_receipt_digest_invalid")
                break
            if (
                receipt.get("sourceRawSnapshotSHA256") != raw_seal.get("snapshotSHA256")
                or receipt.get("sourceIdentitySnapshotSHA256")
                    != identity_seal.get("snapshotSHA256")
                or receipt.get("sourceAdmissionSnapshotSHA256")
                    != admission_seal.get("snapshotSHA256")
                or receipt.get("gapIdentifier", "").lower() != gap_id
                or receipt.get("attemptIdentifier") != final_attempt.get("attemptIdentifier")
                or receipt.get("completionIdentifier") != terminal.get("completionIdentifier")
                or not receipt.get("commitIdentifier")
            ):
                blockers.append("final_consumer_receipt_authority_mismatch")
                break
    if final_authority.get("status") != "resolved" or final_authority.get("resolvedAtUnix") is None:
        blockers.append("final_authority_not_resolved")

    post_ledger, _ = ledger(args.post_resume_full, blockers, "post_ledger")
    post_generation = positive_int(post_ledger.get("generation"))
    post_ids = {
        str(item.get("id", "")).lower() for item in post_ledger.get("windows", [])
        if isinstance(item, dict)
    }
    if gap_id in post_ids:
        blockers.append("exact_gap_not_cas_retired")
    if mid_generation is None or post_generation is None or post_generation <= mid_generation:
        blockers.append("post_ledger_generation_not_advanced")

    marker_expected = marker.get("expectedMaskSHA256")
    if marker_expected is not None and marker_expected != expected_digest:
        blockers.append("marker_expected_mask_digest_mismatch")

    print(f"hist1_resumable_recovery_status={'pass' if not blockers else 'fail'}")
    print(f"gap_identifier={gap_id or 'missing'}")
    print(f"gap_start_unix={start:g}")
    print(f"gap_end_unix={end:g}")
    print(f"gap_duration_seconds={duration:g}")
    print(f"gap_ledger_generation={mid_generation or 0}")
    print(f"gap_ledger_snapshot_sha256={mid_digest}")
    print(f"expected_mask_sha256={expected_digest}")
    print(f"expected_seconds={coverage['expected']}")
    print(f"covered_seconds={coverage['covered']}")
    print(f"coverage_percent={coverage['density']}")
    print(f"maximum_gap_seconds={coverage['maximum_gap']}")
    print(f"p95_gap_seconds={coverage['p95_gap']}")
    print(f"gap_archive_rows={coverage['rows']}")
    print(f"gap_duplicate_identities={coverage['duplicates']}")
    print(f"interrupted_generation={interrupt_generation or 0}")
    print(f"resumed_generation={resume_generation or 0}")
    print(f"consumer_receipts={len(receipts or [])}")
    print(f"post_ledger_generation={post_generation or 0}")
    print("blockers=" + (",".join(blockers) if blockers else "none"))
    return 0 if not blockers else 1


def read_key_values(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return result
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip()
    return result


def require_phase_evidence(
    directory: Path, phase: str, blockers: list[str], label: str,
    require_process: bool,
) -> None:
    record = read_json(directory / "hist1-phase.json", blockers, f"{label}_phase")
    if record.get("phase") != phase or record.get("complete") is not True:
        blockers.append(f"{label}_phase_binding_invalid")
    summary = read_key_values(directory / "pull-summary.txt")
    if summary.get("app_provenance_status") != "pass":
        blockers.append(f"{label}_provenance_not_pass")
    if summary.get("active_journal_final_status") != "ok":
        blockers.append(f"{label}_journal_not_lossless")
    if require_process and summary.get("process_status") != "running":
        blockers.append(f"{label}_process_not_running")


if __name__ == "__main__":
    raise SystemExit(main())
