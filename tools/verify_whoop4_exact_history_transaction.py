#!/usr/bin/env python3
"""Verify one fail-closed WHOOP 4 history-recovery transaction trace.

Two explicitly distinguished transports are accepted:

* the legacy exact-selector trace, whose request binding contains the requested
  Unix bounds; and
* the production full-drain trace, whose matched 22/00 cursor response provides
  clock authority and whose durable gap UUID is carried through the fsynced
  coverage proof and exact gap-resolution CAS. Five typed consumer receipts
  may follow later when their honest future lookahead is available.

The production path deliberately does *not* claim that 22/00 selects a range.
It proves that a full-flash drain resolved one exact durable gap. Returned rows
alone are never authority. Both paths require generation-correlated terminal,
fsync-before-ACK evidence, and ACK acceptance. The production path accepts
`gapResolvedConsumersPending` only after exact ≥90% coverage is persisted;
pending typed projections are not part of missing-HR recovery acceptance.
This is an offline evidence tool: it never launches, terminates, installs, or
talks to the phone.
"""

from __future__ import annotations

import argparse
import math
import re
from dataclasses import dataclass
from pathlib import Path


KEY_RE = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z][A-Za-z0-9_]*)=")
BATCH_BOUNDARY_RE = re.compile(r'^batch\("([^"\\]+)"\)$')


@dataclass(frozen=True)
class Event:
    position: int
    line: str
    fields: dict[str, str]


def fields_after(marker: str, line: str) -> dict[str, str]:
    if marker not in line:
        return {}
    tail = line.split(marker, 1)[1].strip()
    matches = list(KEY_RE.finditer(tail))
    result: dict[str, str] = {}
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(tail)
        result[match.group(1)] = tail[start:end].strip().rstrip(";")
    return result


def events(text: str, marker: str) -> list[Event]:
    result: list[Event] = []
    offset = 0
    for line in text.splitlines(keepends=True):
        if marker in line:
            result.append(Event(offset, line.rstrip(), fields_after(marker, line)))
        offset += len(line)
    return result


def integer(event: Event | None, key: str) -> int | None:
    if event is None:
        return None
    try:
        return int(event.fields[key])
    except (KeyError, ValueError):
        return None


def number(event: Event | None, key: str) -> float | None:
    if event is None:
        return None
    try:
        value = float(event.fields[key])
    except (KeyError, ValueError):
        return None
    return value if math.isfinite(value) else None


def latest_matching(items: list[Event], **fields: str) -> Event | None:
    matching = [
        event for event in items
        if all(event.fields.get(key) == value for key, value in fields.items())
    ]
    return matching[-1] if matching else None


def batch_boundary_key(event: Event) -> str | None:
    match = BATCH_BOUNDARY_RE.fullmatch(event.fields.get("boundary", ""))
    return match.group(1) if match else None


def matching_before(items: list[Event], before: int, **fields: str) -> Event | None:
    matching = [
        event for event in items
        if event.position < before
        and all(event.fields.get(key) == value for key, value in fields.items())
    ]
    return matching[-1] if matching else None


def matching_after(items: list[Event], after: int, **fields: str) -> Event | None:
    matching = [
        event for event in items
        if event.position > after
        and all(event.fields.get(key) == value for key, value in fields.items())
    ]
    return matching[0] if matching else None


def verify(
    text: str,
    requested_start: float,
    requested_end: float,
    window_tolerance_seconds: float = 1.0,
    maximum_clock_drift_seconds: float = 2.0,
    maximum_production_clock_drift_seconds: float = 24 * 60 * 60,
) -> tuple[list[str], dict[str, object]]:
    blockers: list[str] = []
    for label, value in (
        ("window_tolerance", window_tolerance_seconds),
        ("maximum_clock_drift", maximum_clock_drift_seconds),
        ("maximum_production_clock_drift", maximum_production_clock_drift_seconds),
    ):
        if not math.isfinite(value) or value < 0:
            blockers.append(f"invalid_{label}_seconds")

    authority_events = events(text, "ATRIADBG history_request_authority")
    legacy_authority = latest_matching(authority_events, status="bound")
    full_drain_authorities = events(text, "ATRIADBG historical_full_drain_authority")
    production_authority = latest_matching(full_drain_authorities, status="armed")

    transaction_mode = "legacy_exact_selector"
    authority_generation: int | None = None
    attempt: int | None = None
    request_identifier: str | None = None
    gap_identifier: str | None = None
    bound_start: float | None = None
    bound_end: float | None = None
    exact_write: Event | None = None
    clock: Event | None = None
    drift: float | None = None
    range_sequence: int | None = None
    transaction_start = 0
    transaction_evidence_floor = -1

    if legacy_authority is not None and (
        production_authority is None
        or legacy_authority.position > production_authority.position
    ):
        authority_generation = integer(legacy_authority, "authority_generation")
        attempt = integer(legacy_authority, "attempt")
        transport_generation = integer(legacy_authority, "transport_generation")
        request_identifier = legacy_authority.fields.get("request_identifier")
        bound_start = number(legacy_authority, "start_unix")
        bound_end = number(legacy_authority, "end_unix")
        transaction_start = legacy_authority.position
        transaction_text = text[transaction_start:]
        exact_write = latest_matching(
            events(transaction_text, "ATRIADBG historical_exact_range_write"),
            status="confirmed",
        )
        clock = latest_matching(
            events(transaction_text, "ATRIADBG history_clock_authority"),
            status="verified",
        )
        drift = number(clock, "drift_s")

        if authority_generation is None or authority_generation <= 0:
            blockers.append("invalid_authority_generation")
        if attempt is None or attempt <= 0:
            blockers.append("invalid_authority_attempt")
        if transport_generation is None or transport_generation <= 0:
            blockers.append("invalid_transport_generation")
        if not request_identifier:
            blockers.append("missing_request_identifier")
        if bound_start is None or abs(bound_start - requested_start) > window_tolerance_seconds:
            blockers.append("bound_start_does_not_match_requested_window")
        if bound_end is None or abs(bound_end - requested_end) > window_tolerance_seconds:
            blockers.append("bound_end_does_not_match_requested_window")
        if exact_write is None:
            blockers.append("missing_confirmed_exact_range_write")
        elif exact_write.fields.get("exact_interval_authority") != "1":
            blockers.append("exact_range_write_lacks_interval_authority")
        if clock is None:
            blockers.append("missing_attempt_bound_clock_authority")
        elif drift is None or abs(drift) > maximum_clock_drift_seconds:
            blockers.append("clock_authority_drift_out_of_bounds")

        def require_same_identity(event: Event | None, label: str) -> None:
            if event is None:
                return
            comparisons = (
                ("authority_generation", authority_generation),
                ("attempt", attempt),
                ("transport_generation", transport_generation),
            )
            for key, expected in comparisons:
                if integer(event, key) != expected:
                    blockers.append(f"{label}_{key}_mismatch")
            if event.fields.get("request_identifier") != request_identifier:
                blockers.append(f"{label}_request_identifier_mismatch")

        require_same_identity(exact_write, "exact_write")
        require_same_identity(clock, "clock")
    elif production_authority is not None:
        transaction_mode = "production_full_drain_gap_bound"
        transport_generation = integer(production_authority, "generation")
        gap_identifier = production_authority.fields.get("gap")
        selected = matching_before(
            authority_events,
            production_authority.position,
            status="candidate_selected",
            gap=gap_identifier or "",
        )
        transaction_start = selected.position if selected else production_authority.position
        transaction_text = text[transaction_start:]
        # The authority is emitted only after the correlated clock, full-drain
        # write, and history-start proofs are bound.  Batch durability, ACKs,
        # terminal, reconciliation, and publication must belong to the drain
        # after this point; generation alone is not unique across stale logs.
        transaction_evidence_floor = production_authority.position - transaction_start

        if transport_generation is None or transport_generation <= 0:
            blockers.append("invalid_transport_generation")
        if not gap_identifier or gap_identifier == "none":
            blockers.append("missing_durable_gap_identifier")
        if selected is None:
            blockers.append("missing_matching_gap_candidate_selection")

        range_events = events(transaction_text, "ATRIADBG historyRange")
        requested = latest_matching(
            range_events,
            status="requested",
            generation=str(transport_generation),
            payload="00",
            mutation="0",
        )
        range_sequence = integer(requested, "sequence")
        if requested is None or range_sequence is None:
            blockers.append("missing_generation_bound_range_request")
        range_write = matching_after(
            range_events,
            requested.position if requested else -1,
            status="write_confirmed",
            generation=str(transport_generation),
            sequence=str(range_sequence) if range_sequence is not None else "",
            mutation="0",
        )
        if range_write is None:
            blockers.append("missing_generation_bound_range_write_confirmation")
        observed = matching_after(
            range_events,
            requested.position if requested else -1,
            status="observed",
            request_seq_echo=str(range_sequence) if range_sequence is not None else "",
            matched="1",
            mutation="0",
        )
        if observed is None:
            blockers.append("missing_matched_range_response")
        range_proofs_complete_at = max(
            range_write.position if range_write else -1,
            observed.position if observed else -1,
        )
        clock = matching_after(
            range_events,
            range_proofs_complete_at,
            status="matched_clock_authority",
            generation=str(transport_generation),
            sequence=str(range_sequence) if range_sequence is not None else "",
            source="2200",
        )
        drift = number(clock, "drift_s")
        if clock is None:
            blockers.append("missing_attempt_bound_clock_authority")
        elif drift is None or abs(drift) > maximum_production_clock_drift_seconds:
            blockers.append("clock_authority_drift_out_of_bounds")
        observed_pending = integer(observed, "pending")
        clock_pending = integer(clock, "pending")
        if observed is not None and clock is not None and (
            observed_pending is None
            or observed_pending <= 0
            or observed_pending != clock_pending
        ):
            blockers.append("range_response_pending_count_mismatch")
        backlog = matching_after(
            range_events,
            clock.position if clock else -1,
            status="forward_backlog_available",
            generation=str(transport_generation),
            pending=str(clock_pending) if clock_pending is not None else "",
        )
        if backlog is None:
            blockers.append("missing_positive_backlog_authority")
        settled = matching_after(
            range_events,
            backlog.position if backlog else -1,
            status="post_response_settle_confirmed",
            generation=str(transport_generation),
            clock_source="2200",
        )
        if settled is None:
            blockers.append("missing_post_response_settle_confirmation")

        full_write = matching_before(
            events(transaction_text, "ATRIADBG historical_full_drain_write"),
            production_authority.position - transaction_start,
            status="confirmed",
            generation=str(transport_generation),
            command="1600",
            exact_interval_authority="0",
        )
        if full_write is None or (settled is not None and full_write.position <= settled.position):
            blockers.append("missing_ordered_full_drain_write_confirmation")
        drain_sequence = integer(full_write, "sequence")
        starts = events(transaction_text, "ATRIADBG historyMeta")
        history_start = matching_before(
            starts,
            production_authority.position - transaction_start,
            status="start",
            generation=str(transport_generation),
        )
        if history_start is None or (settled is not None and history_start.position <= settled.position):
            blockers.append("missing_generation_bound_history_start")
        if integer(production_authority, "clock_seq") != range_sequence:
            blockers.append("full_drain_clock_sequence_mismatch")
        if integer(production_authority, "drain_seq") != drain_sequence:
            blockers.append("full_drain_command_sequence_mismatch")
        if integer(production_authority, "history_start_seq") != integer(history_start, "sequence"):
            blockers.append("full_drain_history_start_sequence_mismatch")
        exact_write = full_write
    else:
        transport_generation = None
        transaction_text = text
        blockers.extend([
            "missing_exact_request_authority_binding",
            "missing_production_full_drain_authority",
            "invalid_transport_generation",
            "missing_confirmed_exact_range_write",
            "missing_attempt_bound_clock_authority",
        ])

    terminal = latest_matching([
        event for event in events(transaction_text, "ATRIADBG historyTerminal")
        if event.position > transaction_evidence_floor
    ], status="received")
    if terminal is None:
        blockers.append("missing_generation_matching_history_complete")
    elif integer(terminal, "generation") != transport_generation:
        blockers.append("history_complete_transport_generation_mismatch")

    durable = [
        event for event in events(transaction_text, "ATRIADBG historyDrain")
        if event.fields.get("status") == "durable"
        and event.position > transaction_evidence_floor
        and integer(event, "generation") == transport_generation
    ]
    ack_sending = [
        event for event in events(transaction_text, "ATRIADBG historyAck")
        if event.fields.get("status") == "sending"
        and event.position > transaction_evidence_floor
        and integer(event, "generation") == transport_generation
    ]
    ack_confirmed = [
        event for event in events(transaction_text, "ATRIADBG historyAck")
        if event.fields.get("status") in {"confirmed", "accepted"}
        and event.position > transaction_evidence_floor
        and integer(event, "generation") == transport_generation
    ]
    if not durable:
        blockers.append("missing_durable_archive_flush")
    if not ack_sending:
        blockers.append("missing_history_ack_send")
    if not ack_confirmed:
        blockers.append("missing_history_ack_confirmation")

    durable_by_key: dict[str, list[int]] = {}
    for event in durable:
        key = batch_boundary_key(event)
        if not key:
            blockers.append("unparseable_durable_batch_boundary")
            continue
        durable_by_key.setdefault(key, []).append(event.position)
    sends_by_key: dict[str, list[int]] = {}
    for event in ack_sending:
        key = event.fields.get("key", "")
        if key:
            sends_by_key.setdefault(key, []).append(event.position)
    confirmations_by_key: dict[str, list[int]] = {}
    confirmation_events_by_key: dict[str, list[Event]] = {}
    for event in ack_confirmed:
        key = event.fields.get("key", "")
        if key:
            confirmations_by_key.setdefault(key, []).append(event.position)
            confirmation_events_by_key.setdefault(key, []).append(event)

    for send in ack_sending:
        key = send.fields.get("key", "")
        # Match the complete quoted reducer key. Substring matching lets a
        # shorter token borrow another batch's fsync (for example `aa` from
        # `aabb`), which is not archive-before-ACK evidence.
        matching_flushes = durable_by_key.get(key, [])
        if not matching_flushes or max(matching_flushes) >= send.position:
            blockers.append(f"ack_sent_before_matching_fsync:{key or 'missing_key'}")
        later_confirmations = [
            event for event in confirmation_events_by_key.get(key, [])
            if event.position > send.position
            and (
                event.fields.get("status") == "confirmed"
                or integer(event, "attempt") == integer(send, "attempt")
            )
        ]
        if not later_confirmations:
            blockers.append(f"ack_not_confirmed_after_send:{key or 'missing_key'}")
        for confirmation in later_confirmations:
            if confirmation.fields.get("status") == "accepted" and confirmation.fields.get(
                "proof"
            ) not in {
                "confirmed_gatt_write",
                "confirmed_gatt_write_plus_logical_response",
            }:
                blockers.append(f"ack_acceptance_proof_invalid:{key or 'missing_key'}")

    for key in durable_by_key:
        if not sends_by_key.get(key):
            blockers.append(f"durable_batch_missing_ack_send:{key}")
    for confirmation in ack_confirmed:
        key = confirmation.fields.get("key", "")
        earlier_sends = [
            position for position in sends_by_key.get(key, [])
            if position < confirmation.position
        ]
        if not earlier_sends:
            blockers.append(f"ack_confirmation_without_send:{key or 'missing_key'}")

    drain_failures = [
        event for event in events(transaction_text, "ATRIADBG historyDrain")
        if event.fields.get("status") in {"failed", "flush_failed"}
        and event.position > transaction_evidence_floor
        and integer(event, "generation") == transport_generation
    ]
    if drain_failures:
        blockers.append("history_drain_failed")

    consumers: Event | None
    if transaction_mode == "legacy_exact_selector":
        consumers = latest_matching(
            events(transaction_text, "ATRIADBG historical_consumers"), status="committed"
        )
    else:
        persisted_coverage = latest_matching(
            [
                event for event in events(
                    transaction_text, "ATRIADBG historical_full_drain_coverage"
                )
                if event.position > transaction_evidence_floor
            ],
            gap=gap_identifier or "",
            generation=str(transport_generation),
            status="persisted",
        )
        reconcile = latest_matching(
            [
                event for event in events(
                    transaction_text, "ATRIADBG historical_full_drain_reconcile"
                )
                if event.position > transaction_evidence_floor
            ],
            gap=gap_identifier or "",
            generation=str(transport_generation),
            status="resolved",
        )
        coverage = persisted_coverage or reconcile
        if coverage is None:
            blockers.append("missing_exact_gap_coverage_resolution")
        else:
            if terminal is not None and coverage.position <= terminal.position:
                blockers.append("gap_coverage_resolved_before_history_terminal")
            density = integer(coverage, "density")
            maximum_gap = integer(coverage, "maximum_gap")
            p95_gap = integer(coverage, "p95_gap")
            if density is None or density < 90:
                blockers.append("resolved_gap_density_below_90_percent")
            if maximum_gap is None or maximum_gap > 3:
                blockers.append("resolved_gap_maximum_gap_over_3s")
            if p95_gap is None or p95_gap > 1:
                blockers.append("resolved_gap_p95_gap_over_1s")
        publish_events = events(
            transaction_text, "ATRIADBG historical_full_drain_publish"
        )
        publish_events = [
            event for event in publish_events
            if event.position > transaction_evidence_floor
        ]
        consumers = latest_matching(
            publish_events,
            status="resolved",
            generation=str(transport_generation),
            gap=gap_identifier or "",
            receipts="5",
        ) or latest_matching(
            publish_events,
            status="resolved_after_consumers_pending",
            generation=str(transport_generation),
            gap=gap_identifier or "",
            receipts="5",
        )
        pending_consumers = latest_matching(
            publish_events,
            status="gap_resolved_consumers_pending",
            generation=str(transport_generation),
            gap=gap_identifier or "",
            receipts="0",
        )
        if consumers is None and pending_consumers is None:
            blockers.append("missing_exact_gap_resolution_commit")
            blockers.append("missing_committed_verified_consumers")
        if (
            consumers is not None
            and coverage is not None
            and consumers.position <= coverage.position
        ):
            blockers.append("consumers_committed_before_gap_coverage_resolution")

    if consumers is None and transaction_mode == "legacy_exact_selector":
        blockers.append("missing_committed_verified_consumers")
    elif transaction_mode == "legacy_exact_selector":
        if integer(consumers, "authority_generation") != authority_generation:
            blockers.append("consumer_authority_generation_mismatch")
        if integer(consumers, "attempt") != attempt:
            blockers.append("consumer_authority_attempt_mismatch")
        if integer(consumers, "transport_generation") != transport_generation:
            blockers.append("consumer_transport_generation_mismatch")
        if integer(consumers, "receipts") != 5:
            blockers.append("verified_consumer_receipt_set_incomplete")
        if terminal is not None and consumers.position <= terminal.position:
            blockers.append("consumers_committed_before_history_terminal")
        if ack_confirmed and consumers.position <= max(event.position for event in ack_confirmed):
            blockers.append("consumers_committed_before_final_ack_confirmation")
    elif consumers is not None:
        if ack_confirmed and consumers.position <= max(event.position for event in ack_confirmed):
            blockers.append("consumers_committed_before_final_ack_confirmation")
        if (
            transaction_mode == "production_full_drain_gap_bound"
            and terminal is not None
            and consumers.position <= terminal.position
        ):
            blockers.append("consumers_committed_before_history_terminal")

    completion = latest_matching(
        [
            event for event in events(transaction_text, "ATRIADBG offline_sync")
            if event.position > transaction_evidence_floor
        ],
        status="complete",
    )
    if completion is None:
        blockers.append("missing_offline_sync_completion")
    elif not completion.fields.get("reason", "").endswith("_terminal"):
        blockers.append("offline_sync_completion_not_terminal")
    if completion is not None:
        completion_generation = integer(completion, "generation")
        if completion_generation is not None and completion_generation != transport_generation:
            blockers.append("offline_sync_completion_generation_mismatch")
        if (
            transaction_mode == "production_full_drain_gap_bound"
            and completion.fields.get("live_restored") != "1"
        ):
            blockers.append("offline_sync_completion_live_not_restored")
    if terminal is not None and completion is not None:
        # Positions in transaction_text share the same coordinate system.
        if completion.position <= terminal.position:
            blockers.append("offline_sync_completed_before_history_terminal")
    if ack_confirmed and completion is not None:
        if completion.position <= max(event.position for event in ack_confirmed):
            blockers.append("offline_sync_completed_before_final_ack_confirmation")

    if transaction_mode == "legacy_exact_selector":
        deferred_after_binding = [
            event for event in events(transaction_text, "ATRIADBG history_request_authority")
            if event.fields.get("status") == "deferred"
        ]
        if deferred_after_binding:
            blockers.append("request_authority_deferred_after_binding")

    details: dict[str, object] = {
        "transaction_mode": transaction_mode,
        "authority_generation": authority_generation or 0,
        "attempt": attempt or 0,
        "transport_generation": transport_generation or 0,
        "request_identifier": request_identifier or "missing",
        "gap_identifier": gap_identifier or "missing",
        "bound_start_unix": bound_start if bound_start is not None else "missing",
        "bound_end_unix": bound_end if bound_end is not None else "missing",
        "requested_bounds_verified": 1 if transaction_mode == "legacy_exact_selector" else 0,
        "exact_range_write_confirmed": 1
        if transaction_mode == "legacy_exact_selector" and exact_write else 0,
        "full_drain_write_confirmed": 1
        if transaction_mode == "production_full_drain_gap_bound" and exact_write else 0,
        "range_sequence": range_sequence if range_sequence is not None else "missing",
        "clock_authority_verified": 1 if clock else 0,
        "clock_drift_s": drift if drift is not None else "missing",
        "history_complete_received": 1 if terminal else 0,
        "durable_flushes": len(durable),
        "ack_sends": len(ack_sending),
        "ack_confirmations": len(ack_confirmed),
        "consumer_receipts": integer(consumers, "receipts") or 0,
        "offline_sync_complete": 1 if completion else 0,
    }
    return blockers, details


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recovery-log", required=True, type=Path)
    parser.add_argument("--requested-start-unix", required=True, type=float)
    parser.add_argument("--requested-end-unix", required=True, type=float)
    parser.add_argument("--window-tolerance-seconds", type=float, default=1.0)
    parser.add_argument("--maximum-clock-drift-seconds", type=float, default=2.0)
    parser.add_argument(
        "--maximum-production-clock-drift-seconds",
        type=float,
        default=24 * 60 * 60,
        help=(
            "WHOOP production clock correction bound. Full validation also "
            "requires the persisted transport authority checked by the "
            "resumable HIST-1 verifier."
        ),
    )
    args = parser.parse_args()
    if not args.recovery_log.is_file():
        parser.error(f"missing recovery log: {args.recovery_log}")
    if not math.isfinite(args.requested_start_unix) or not math.isfinite(args.requested_end_unix):
        parser.error("requested bounds must be finite")
    if args.requested_start_unix <= 0 or args.requested_end_unix <= args.requested_start_unix:
        parser.error("requested bounds must form a positive closed interval")
    blockers, details = verify(
        args.recovery_log.read_text(encoding="utf-8", errors="replace"),
        args.requested_start_unix,
        args.requested_end_unix,
        args.window_tolerance_seconds,
        args.maximum_clock_drift_seconds,
        args.maximum_production_clock_drift_seconds,
    )
    print(f"exact_history_transaction_status={'pass' if not blockers else 'fail'}")
    print(f"recovery_log={args.recovery_log}")
    print(f"requested_start_unix={args.requested_start_unix:g}")
    print(f"requested_end_unix={args.requested_end_unix:g}")
    for key, value in details.items():
        print(f"{key}={value}")
    print("blockers=" + (",".join(blockers) if blockers else "none"))
    return 0 if not blockers else 1


if __name__ == "__main__":
    raise SystemExit(main())
