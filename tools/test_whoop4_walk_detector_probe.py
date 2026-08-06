#!/usr/bin/env python3
"""Offline safety tests for whoop4_walk_detector_probe.py."""

from __future__ import annotations

import asyncio
import io
import json
import tempfile
import types
import unittest
import zlib
from dataclasses import replace
from pathlib import Path
from unittest import mock

from tools import whoop4_walk_detector_probe as probe


PERIPHERAL = probe.PINNED_PERIPHERAL_ID
OTHER_PERIPHERAL = "C125C62E-C432-53E7-BD19-9761251B2C3E"


def pinned_entries() -> list[probe.FeatureFlagEntry]:
    return [
        probe.FeatureFlagEntry(
            revision=probe.PINNED_ENUMERATION_REVISION,
            index=index,
            valid=True,
            key=key,
        )
        for index, key in enumerate(probe.PINNED_ENUMERATION_KEYS)
    ]


def frame_from_inner(inner: bytes) -> bytes:
    length = len(inner) + 4
    length_bytes = length.to_bytes(2, "little")
    return (
        b"\xAA"
        + length_bytes
        + bytes((probe.crc8(length_bytes),))
        + inner
        + (zlib.crc32(inner) & 0xFFFFFFFF).to_bytes(4, "little")
    )


def response_frame(
    opcode: int,
    record: bytes,
    sequence: int = 9,
    request_sequence: int = 0x0A,
) -> bytes:
    inner = bytes(
        (
            probe.COMMAND_RESPONSE_PACKET_TYPE,
            sequence,
            opcode,
            request_sequence,
            0x01,
        )
    ) + record
    return frame_from_inner(inner)


def data_range_response_frame(
    *,
    write_cursor: int,
    read_cursor: int,
    device_unix: int,
    capacity: int = 131_072,
    sequence: int = 9,
    request_sequence: int = 1,
) -> bytes:
    inner = bytearray(70)
    inner[0] = probe.COMMAND_RESPONSE_PACKET_TYPE
    inner[1] = sequence
    inner[2] = probe.GET_DATA_RANGE
    inner[3] = request_sequence
    inner[4:6] = b"\x01\x01"
    inner[14:18] = write_cursor.to_bytes(4, "little")
    inner[18:22] = read_cursor.to_bytes(4, "little")
    inner[26:30] = capacity.to_bytes(4, "little")
    inner[62:66] = device_unix.to_bytes(4, "little")
    return frame_from_inner(bytes(inner))


class CommandSafetyTests(unittest.TestCase):
    def test_allowlist_is_exactly_three_feature_commands(self) -> None:
        self.assertEqual(
            probe.ALLOWED_OPCODES,
            {
                probe.START_FF_KEY_EXCHANGE,
                probe.SEND_NEXT_FF,
                probe.SET_FF_VALUE,
            },
        )
        self.assertEqual(
            probe.ALLOWED_OPCODES,
            {0x75, 0x76, 0x78},
        )

    def test_enumeration_commands_accept_only_payload_01(self) -> None:
        for opcode in (
            probe.START_FF_KEY_EXCHANGE,
            probe.SEND_NEXT_FF,
        ):
            frame = probe.command_frame(opcode, b"\x01", 7)
            inner = probe.frame_inner(frame)
            self.assertEqual(inner, bytes((0x23, 7, opcode, 0x01)))
            for rejected in (b"", b"\x00", b"\x01\x00"):
                with self.assertRaises(probe.ProbeRefusal):
                    probe.command_frame(opcode, rejected, 7)

    def test_every_nonallowlisted_opcode_is_refused(self) -> None:
        for opcode in range(256):
            if opcode in probe.ALLOWED_OPCODES:
                continue
            with self.assertRaises(probe.ProbeRefusal):
                probe.command_frame(opcode, b"\x00", 1)

    def test_persistent_payload_is_exact_key_and_ascii_one_value(self) -> None:
        payload = probe.target_set_payload(
            "enable_false_step_detection", "1"
        )
        self.assertEqual(len(payload), 65)
        self.assertEqual(payload, probe.TARGET_SET_PAYLOAD)
        frame = probe.command_frame(0x78, payload, 4)
        self.assertEqual(probe.frame_inner(frame)[3:], payload)

        for key in (*probe.PINNED_ENUMERATION_KEYS, ""):
            if key == probe.TARGET_FEATURE_KEY:
                continue
            with self.assertRaises(probe.ProbeRefusal):
                probe.target_set_payload(key, "1")
        for value in ("2", "0", "", "true"):
            with self.assertRaises(probe.ProbeRefusal):
                probe.target_set_payload(
                    "enable_false_step_detection", value
                )

    def test_arbitrary_set_payload_is_refused(self) -> None:
        rejected = (
            b"",
            b"\x01",
            probe.TARGET_SET_PAYLOAD[:-1],
            probe.TARGET_SET_PAYLOAD[:-1] + b"\x01",
            b"\x01"
            + b"enable_r19_packets".ljust(32, b"\x00")
            + b"1".ljust(32, b"\x00"),
        )
        for payload in rejected:
            with self.assertRaises(probe.ProbeRefusal):
                probe.command_frame(0x78, payload, 1)

    def test_frame_crc_rejects_corruption(self) -> None:
        frame = bytearray(
            probe.command_frame(0x75, probe.ENUMERATION_PAYLOAD, 2)
        )
        frame[-1] ^= 0x80
        with self.assertRaises(probe.ProbeTransportError):
            probe.frame_inner(bytes(frame))


class PinnedEnumerationEvidenceTests(unittest.TestCase):
    def test_pinned_physical_artifact_matches_exact_audited_snapshot(
        self,
    ) -> None:
        evidence = probe.verify_pinned_enumeration_evidence()
        self.assertEqual(
            evidence["peripheralID"],
            probe.PINNED_PERIPHERAL_ID,
        )
        self.assertEqual(
            evidence["enumeration"]["revision"],
            probe.PINNED_ENUMERATION_REVISION,
        )
        self.assertEqual(
            evidence["enumeration"]["keys"],
            list(probe.PINNED_ENUMERATION_KEYS),
        )
        self.assertFalse(evidence["setWriteAttempted"])

    def test_pinned_artifact_hash_and_content_are_both_required(self) -> None:
        raw = probe.PINNED_ENUMERATION_EVIDENCE_PATH.read_bytes()
        with tempfile.TemporaryDirectory() as temporary:
            changed_path = Path(temporary) / "changed.json"
            changed = json.loads(raw)
            changed["enumeration"]["keys"][0] = "changed"
            changed_raw = (
                json.dumps(changed, sort_keys=True) + "\n"
            ).encode()
            changed_path.write_bytes(changed_raw)

            with self.assertRaisesRegex(probe.ProbeRefusal, "SHA-256"):
                probe.verify_pinned_enumeration_evidence(changed_path)

            changed_digest = probe.hashlib.sha256(changed_raw).hexdigest()
            with (
                mock.patch.object(
                    probe,
                    "PINNED_ENUMERATION_EVIDENCE_SHA256",
                    changed_digest,
                ),
                self.assertRaisesRegex(
                    probe.ProbeRefusal,
                    "content does not match",
                ),
            ):
                probe.verify_pinned_enumeration_evidence(changed_path)

    def test_same_run_snapshot_requires_exact_revision_order_and_indices(
        self,
    ) -> None:
        start = probe.FeatureFlagStart(
            revision=probe.PINNED_ENUMERATION_REVISION,
            count=len(probe.PINNED_ENUMERATION_KEYS),
        )
        entries = pinned_entries()
        self.assertEqual(
            probe.require_pinned_feature_enumeration(
                peripheral_id=PERIPHERAL,
                start=start,
                entries=entries,
            ),
            probe.PINNED_ENUMERATION_KEYS,
        )

        mutations = [
            (
                replace(start, revision=2),
                entries,
            ),
            (
                replace(start, count=start.count - 1),
                entries,
            ),
            (
                start,
                entries[:-1],
            ),
            (
                start,
                [
                    entries[1],
                    entries[0],
                    *entries[2:],
                ],
            ),
            (
                start,
                [
                    replace(entries[0], revision=2),
                    *entries[1:],
                ],
            ),
            (
                start,
                [
                    entries[0],
                    replace(entries[1], index=0),
                    *entries[2:],
                ],
            ),
            (
                start,
                [
                    entries[0],
                    replace(
                        entries[1],
                        key=probe.TARGET_FEATURE_KEY,
                    ),
                    *entries[2:],
                ],
            ),
        ]
        for changed_start, changed_entries in mutations:
            with self.subTest(
                start=changed_start,
                entries=changed_entries,
            ):
                with self.assertRaises(probe.ProbeRefusal):
                    probe.require_pinned_feature_enumeration(
                        peripheral_id=PERIPHERAL,
                        start=changed_start,
                        entries=changed_entries,
                    )

        with self.assertRaises(probe.ProbeRefusal):
            probe.require_pinned_feature_enumeration(
                peripheral_id=OTHER_PERIPHERAL,
                start=start,
                entries=entries,
            )


class FirstChunkHistorySafetyTests(unittest.TestCase):
    def test_history_allowlist_is_only_zero_payload_range_serve_abort(self) -> None:
        self.assertEqual(
            probe.HISTORY_OBSERVATION_OPCODES,
            {0x22, 0x16, 0x14},
        )
        for opcode in probe.HISTORY_OBSERVATION_OPCODES:
            frame = probe.history_command_frame(opcode, b"\x00", 7)
            self.assertEqual(probe.frame_inner(frame)[2], opcode)
        for opcode in range(256):
            if opcode in probe.HISTORY_OBSERVATION_OPCODES:
                continue
            with self.assertRaises(probe.ProbeRefusal):
                probe.history_command_frame(opcode, b"\x00", 7)

    def test_selector_and_ack_are_impossible(self) -> None:
        selector = (
            (1_785_000_000).to_bytes(4, "little")
            + (1_785_000_600).to_bytes(4, "little")
        )
        with self.assertRaises(probe.ProbeRefusal):
            probe.history_command_frame(0x16, selector, 1)
        with self.assertRaises(probe.ProbeRefusal):
            probe.history_command_frame(0x17, b"\x01" + bytes(8), 1)
        for opcode in probe.HISTORY_OBSERVATION_OPCODES:
            for payload in (b"", b"\x01", b"\x00\x00"):
                with self.assertRaises(probe.ProbeRefusal):
                    probe.history_command_frame(opcode, payload, 1)

    def test_data_range_coordinates_use_documented_full_frame_offsets(self) -> None:
        frame = data_range_response_frame(
            write_cursor=123,
            read_cursor=45,
            device_unix=1_785_000_000,
        )
        self.assertEqual(
            probe.parse_data_range_cursor_frame(frame),
            probe.DataRangeCursor(
                write_cursor=123,
                read_cursor=45,
                capacity=131_072,
                device_unix=1_785_000_000,
            ),
        )

    def test_data_range_parser_matches_physical_whoop4_capture(self) -> None:
        # Complete decoded inner payload from the successful 2026-07-20
        # read-only capture. This pins capacity and device time to their real
        # locations instead of allowing a synthetic offset to drift.
        inner = bytes.fromhex(
            "24a722000101c0080000c508000091080000c008000012000000"
            "0000020002531300d60100002f634a6a482d00002f634a6a482d"
            "00005f634a6aa03500001e2b5d6a707d00000000"
        )
        self.assertEqual(
            probe.parse_data_range_cursor_frame(frame_from_inner(inner)),
            probe.DataRangeCursor(
                write_cursor=2_193,
                read_cursor=2_240,
                capacity=131_072,
                device_unix=1_784_490_782,
            ),
        )

    def test_data_range_parser_rejects_unproven_shape_and_coordinates(self) -> None:
        valid = data_range_response_frame(
            write_cursor=123,
            read_cursor=45,
            device_unix=1_785_000_000,
        )
        valid_inner = bytearray(probe.frame_inner(valid))

        bad_prefix = bytearray(valid_inner)
        bad_prefix[5] = 0
        with self.assertRaises(probe.ProbeTransportError):
            probe.parse_data_range_cursor_frame(
                frame_from_inner(bytes(bad_prefix))
            )

        short = bytes(valid_inner[:30])
        with self.assertRaises(probe.ProbeTransportError):
            probe.parse_data_range_cursor_frame(frame_from_inner(short))

        bad_capacity = bytearray(valid_inner)
        bad_capacity[26:30] = (100).to_bytes(4, "little")
        with self.assertRaises(probe.ProbeTransportError):
            probe.parse_data_range_cursor_frame(
                frame_from_inner(bytes(bad_capacity))
            )

    def test_nonempty_preflight_blocks_before_persistent_write(self) -> None:
        with self.assertRaises(probe.ProbeRefusal):
            probe.require_empty_history_preflight(
                probe.DataRangeCursor(
                    write_cursor=101,
                    read_cursor=100,
                    capacity=131_072,
                    device_unix=1_785_000_000,
                )
            )
        probe.require_empty_history_preflight(
            probe.DataRangeCursor(
                write_cursor=100,
                read_cursor=100,
                capacity=131_072,
                device_unix=1_785_000_000,
            )
        )

    def test_postflight_requires_same_cursor_space_and_monotonic_clock(self) -> None:
        preflight = probe.DataRangeCursor(
            write_cursor=100,
            read_cursor=100,
            capacity=131_072,
            device_unix=1_785_000_000,
        )
        self.assertTrue(
            probe.postflight_preserves_cursor_space(
                preflight,
                probe.DataRangeCursor(
                    write_cursor=140,
                    read_cursor=100,
                    capacity=131_072,
                    device_unix=1_785_000_040,
                ),
            )
        )
        for postflight in (
            probe.DataRangeCursor(
                write_cursor=140,
                read_cursor=101,
                capacity=131_072,
                device_unix=1_785_000_040,
            ),
            probe.DataRangeCursor(
                write_cursor=140,
                read_cursor=100,
                capacity=262_144,
                device_unix=1_785_000_040,
            ),
            probe.DataRangeCursor(
                write_cursor=140,
                read_cursor=100,
                capacity=131_072,
                device_unix=1_784_999_999,
            ),
        ):
            self.assertFalse(
                probe.postflight_preserves_cursor_space(
                    preflight, postflight
                )
            )


class FirstChunkHistoryTraceTests(unittest.IsolatedAsyncioTestCase):
    async def test_nonempty_preflight_keeps_persistent_write_unreachable(
        self,
    ) -> None:
        class FakeClient:
            def __init__(self) -> None:
                self.writes: list[bytes] = []
                self.channel: probe.CommandChannel | None = None

            async def write_gatt_char(
                self, _: str, frame: bytes, response: bool
            ) -> None:
                del response
                self.writes.append(frame)
                if probe.frame_inner(frame)[2] == probe.GET_DATA_RANGE:
                    assert self.channel is not None
                    request_sequence = probe.frame_inner(frame)[1]
                    self.channel.receive_frames(
                        [
                            data_range_response_frame(
                                write_cursor=11,
                                read_cursor=10,
                                device_unix=1_785_000_000,
                                request_sequence=request_sequence,
                            )
                        ]
                    )

        with tempfile.TemporaryDirectory() as temporary:
            recorder = probe.CorpusRecorder(
                Path(temporary) / "corpus.jsonl"
            )
            client = FakeClient()
            channel = probe.CommandChannel(
                client,
                recorder,
                persistent_write_authorized=True,
                empty_history_preflight_required=True,
            )
            client.channel = channel
            try:
                cursor = await channel.call_data_range(timeout_seconds=1)
                with self.assertRaises(probe.ProbeRefusal):
                    channel.authorize_after_empty_history_preflight(cursor)
                with self.assertRaises(probe.ProbeRefusal):
                    await channel.call(
                        probe.SET_FF_VALUE,
                        probe.TARGET_SET_PAYLOAD,
                        timeout_seconds=1,
                    )
                self.assertEqual(
                    [probe.frame_inner(frame)[2] for frame in client.writes],
                    [0x22],
                )
            finally:
                recorder.close()

    async def test_trace_is_preflight_serve_abort_postflight_no_ack(self) -> None:
        class FakeClient:
            def __init__(self) -> None:
                self.writes: list[bytes] = []
                self.channel: probe.CommandChannel | None = None
                self.range_responses = [
                    data_range_response_frame(
                        write_cursor=10,
                        read_cursor=10,
                        device_unix=1_785_000_000,
                    ),
                    data_range_response_frame(
                        write_cursor=40,
                        read_cursor=10,
                        device_unix=1_785_000_040,
                    ),
                ]

            async def write_gatt_char(
                self, _: str, frame: bytes, response: bool
            ) -> None:
                self.assert_response = response
                self.writes.append(frame)
                if probe.frame_inner(frame)[2] == probe.GET_DATA_RANGE:
                    assert self.channel is not None
                    response_inner = bytearray(
                        probe.frame_inner(self.range_responses.pop(0))
                    )
                    response_inner[3] = probe.frame_inner(frame)[1]
                    self.channel.receive_frames(
                        [frame_from_inner(bytes(response_inner))]
                    )

        class FakeRecorder:
            def __init__(self) -> None:
                self.phases: list[str] = []

            def set_phase(self, phase: str) -> None:
                self.phases.append(phase)

        with tempfile.TemporaryDirectory() as temporary:
            corpus = probe.CorpusRecorder(Path(temporary) / "unused.jsonl")
            client = FakeClient()
            channel = probe.CommandChannel(client, corpus)
            client.channel = channel
            preflight = await channel.call_data_range(timeout_seconds=1)
            corpus.close()
            budget = probe.HistoryCaptureBudget(
                timeout_seconds=1, byte_cap=1024
            )
            budget.stop_reason = "first_history_end"
            budget.first_history_end_hex = "310002" + "00" * 18
            budget.historical_timestamps = [100, 110, 120, 130]
            budget.stop_event.set()
            phases = [
                {
                    "phase": "pre_enable_positive_walk",
                    "startedAtUnix": 99,
                    "endedAtUnix": 101,
                },
                {
                    "phase": "pre_enable_arm_motion_control",
                    "startedAtUnix": 109,
                    "endedAtUnix": 111,
                },
                {
                    "phase": "post_enable_positive_walk",
                    "startedAtUnix": 119,
                    "endedAtUnix": 121,
                },
                {
                    "phase": "post_enable_arm_motion_control",
                    "startedAtUnix": 129,
                    "endedAtUnix": 131,
                },
            ]
            result = await probe.observe_first_fifo_chunk(
                channel,
                FakeRecorder(),  # type: ignore[arg-type]
                probe.BankedDiscoveryObservation(
                    timeout_seconds=1, byte_cap=1024
                ),
                budget,
                preflight,
                phases,
                response_timeout_seconds=1,
                post_abort_settle_seconds=0,
            )

        opcodes = [probe.frame_inner(frame)[2] for frame in client.writes]
        self.assertEqual(opcodes, [0x22, 0x16, 0x14, 0x22])
        self.assertNotIn(0x17, opcodes)
        self.assertEqual(probe.frame_inner(client.writes[1])[3:], b"\x00")
        self.assertEqual(result["commandTrace"], ["0x22", "0x16", "0x14", "0x22"])
        self.assertTrue(result["readCursorUnchanged"])
        self.assertTrue(result["capacityUnchanged"])
        self.assertTrue(result["deviceClockNonregressing"])
        self.assertTrue(result["cursorSpaceUnchanged"])
        self.assertEqual(
            result["verdict"],
            "candidate_first_chunk_rows_observed_requires_signal_decoding",
        )
        self.assertEqual(
            result["labelledRowsByPhase"],
            {
                "pre_enable_positive_walk": 1,
                "pre_enable_arm_motion_control": 1,
                "post_enable_positive_walk": 1,
                "post_enable_arm_motion_control": 1,
            },
        )
        self.assertFalse(result["historyACKSent"])

    async def test_out_of_order_history_trace_is_refused(self) -> None:
        class FakeClient:
            async def write_gatt_char(
                self, _: str, frame: bytes, response: bool
            ) -> None:
                del frame, response

        with tempfile.TemporaryDirectory() as temporary:
            recorder = probe.CorpusRecorder(
                Path(temporary) / "corpus.jsonl"
            )
            channel = probe.CommandChannel(FakeClient(), recorder)
            try:
                with self.assertRaises(probe.ProbeRefusal):
                    await channel.write_history_command(0x16, b"\x00")
                with self.assertRaises(probe.ProbeRefusal):
                    await channel.write_history_command(0x17, b"\x00")
            finally:
                recorder.close()


class HistoryBudgetTests(unittest.IsolatedAsyncioTestCase):
    async def test_byte_cap_rejects_whole_crossing_notification(self) -> None:
        budget = probe.HistoryCaptureBudget(
            timeout_seconds=1, byte_cap=10
        )
        budget.begin()
        self.assertTrue(budget.admits(6))
        self.assertFalse(budget.admits(5))
        self.assertEqual(await budget.wait(), "byte_cap_before_notification")
        self.assertEqual(budget.accepted_bytes, 6)
        self.assertEqual(budget.rejected_bytes, 5)

    async def test_only_rows_through_first_history_end_are_classified(self) -> None:
        budget = probe.HistoryCaptureBudget(
            timeout_seconds=1, byte_cap=4096
        )
        first_row = bytearray(12)
        first_row[0] = probe.HISTORICAL_PACKET_TYPE
        first_row[1] = 24
        first_row[7:11] = (100).to_bytes(4, "little")
        second_row = bytearray(first_row)
        second_row[7:11] = (101).to_bytes(4, "little")
        history_end = bytearray(21)
        history_end[0] = 0x31
        history_end[2] = 0x02
        budget.begin()
        budget.observe_frames(
            [
                frame_from_inner(bytes(first_row)),
                frame_from_inner(bytes(history_end)),
                frame_from_inner(bytes(second_row)),
            ]
        )
        self.assertEqual(await budget.wait(), "first_history_end")
        self.assertEqual(budget.historical_rows, 1)
        self.assertEqual(budget.historical_timestamps, [100])
        self.assertIsNotNone(budget.first_history_end_hex)

    async def test_deadline_closes_data_even_before_wait_is_called(self) -> None:
        budget = probe.HistoryCaptureBudget(
            timeout_seconds=0.001, byte_cap=4096
        )
        budget.begin()
        await asyncio.sleep(0.01)
        self.assertFalse(budget.admits(128))
        self.assertEqual(budget.accepted_bytes, 0)
        self.assertEqual(budget.stop_reason, "time_cap")
        self.assertEqual(await budget.wait(), "time_cap")


class ResponseSequenceCorrelationTests(unittest.IsolatedAsyncioTestCase):
    async def test_feature_call_ignores_stale_same_opcode_response(self) -> None:
        class FakeClient:
            def __init__(self) -> None:
                self.channel: probe.CommandChannel | None = None

            async def write_gatt_char(
                self, _: str, frame: bytes, response: bool
            ) -> None:
                del response
                request_sequence = probe.frame_inner(frame)[1]
                assert self.channel is not None
                self.channel.receive_frames(
                    [
                        response_frame(
                            probe.START_FF_KEY_EXCHANGE,
                            bytes((1, 99, 0)),
                            request_sequence=(
                                request_sequence - 1
                            ) & 0xFF,
                        ),
                        response_frame(
                            probe.START_FF_KEY_EXCHANGE,
                            bytes((1, 11, 0)),
                            request_sequence=request_sequence,
                        ),
                    ]
                )

        with tempfile.TemporaryDirectory() as temporary:
            recorder = probe.CorpusRecorder(
                Path(temporary) / "corpus.jsonl"
            )
            client = FakeClient()
            channel = probe.CommandChannel(client, recorder)
            client.channel = channel
            try:
                inner = await channel.call(
                    probe.START_FF_KEY_EXCHANGE,
                    probe.ENUMERATION_PAYLOAD,
                    timeout_seconds=1,
                )
                self.assertEqual(inner[3], 1)
                self.assertEqual(
                    probe.decode_start_response(inner).count,
                    11,
                )
            finally:
                recorder.close()

    async def test_data_range_ignores_stale_empty_cursor_response(self) -> None:
        class FakeClient:
            def __init__(self) -> None:
                self.channel: probe.CommandChannel | None = None

            async def write_gatt_char(
                self, _: str, frame: bytes, response: bool
            ) -> None:
                del response
                request_sequence = probe.frame_inner(frame)[1]
                assert self.channel is not None
                self.channel.receive_frames(
                    [
                        data_range_response_frame(
                            write_cursor=10,
                            read_cursor=10,
                            device_unix=1_785_000_000,
                            request_sequence=(
                                request_sequence - 1
                            ) & 0xFF,
                        ),
                        data_range_response_frame(
                            write_cursor=11,
                            read_cursor=10,
                            device_unix=1_785_000_001,
                            request_sequence=request_sequence,
                        ),
                    ]
                )

        with tempfile.TemporaryDirectory() as temporary:
            recorder = probe.CorpusRecorder(
                Path(temporary) / "corpus.jsonl"
            )
            client = FakeClient()
            channel = probe.CommandChannel(client, recorder)
            client.channel = channel
            try:
                cursor = await channel.call_data_range(timeout_seconds=1)
                self.assertEqual(cursor.write_cursor, 11)
                self.assertEqual(cursor.read_cursor, 10)
                with self.assertRaises(probe.ProbeRefusal):
                    probe.require_empty_history_preflight(cursor)
            finally:
                recorder.close()


class SingleWriteAttemptTests(unittest.IsolatedAsyncioTestCase):
    async def test_persistent_write_without_ack_authority_never_reaches_client(
        self,
    ) -> None:
        class FakeClient:
            def __init__(self) -> None:
                self.writes: list[bytes] = []

            async def write_gatt_char(
                self, _: str, frame: bytes, response: bool
            ) -> None:
                del response
                self.writes.append(frame)

        with tempfile.TemporaryDirectory() as temporary:
            recorder = probe.CorpusRecorder(
                Path(temporary) / "corpus.jsonl"
            )
            client = FakeClient()
            channel = probe.CommandChannel(client, recorder)
            try:
                with self.assertRaises(probe.ProbeRefusal):
                    await channel.call(
                        probe.SET_FF_VALUE,
                        probe.TARGET_SET_PAYLOAD,
                        timeout_seconds=1,
                    )
                self.assertEqual(client.writes, [])
            finally:
                recorder.close()

    async def test_persistent_write_timeout_is_never_retried(self) -> None:
        class FakeClient:
            def __init__(self) -> None:
                self.writes: list[bytes] = []

            async def write_gatt_char(
                self, _: str, frame: bytes, response: bool
            ) -> None:
                self.assert_response = response
                self.writes.append(frame)

        with tempfile.TemporaryDirectory() as temporary:
            recorder = probe.CorpusRecorder(
                Path(temporary) / "corpus.jsonl"
            )
            client = FakeClient()
            guard = probe.DurableSetAttemptGuard(
                Path(temporary) / "attempt-guards",
                PERIPHERAL,
            )
            channel = probe.CommandChannel(
                client,
                recorder,
                persistent_write_authorized=True,
                persistent_attempt_guard=guard.claim,
            )
            try:
                with self.assertRaises(probe.ProbeTransportError):
                    await channel.call(
                        probe.SET_FF_VALUE,
                        probe.TARGET_SET_PAYLOAD,
                        timeout_seconds=0.001,
                    )
                self.assertEqual(len(client.writes), 1)
                self.assertEqual(
                    probe.frame_inner(client.writes[0])[2],
                    probe.SET_FF_VALUE,
                )
                with self.assertRaises(probe.ProbeRefusal):
                    await channel.call(
                        probe.SET_FF_VALUE,
                        probe.TARGET_SET_PAYLOAD,
                        timeout_seconds=0.001,
                    )
                self.assertEqual(len(client.writes), 1)

                second_client = FakeClient()
                second_guard = probe.DurableSetAttemptGuard(
                    Path(temporary) / "attempt-guards",
                    PERIPHERAL,
                )
                second_channel = probe.CommandChannel(
                    second_client,
                    recorder,
                    persistent_write_authorized=True,
                    persistent_attempt_guard=second_guard.claim,
                )
                with self.assertRaises(probe.ProbeRefusal):
                    await second_channel.call(
                        probe.SET_FF_VALUE,
                        probe.TARGET_SET_PAYLOAD,
                        timeout_seconds=0.001,
                    )
                self.assertEqual(second_client.writes, [])
                self.assertTrue(guard.path.exists())
                self.assertEqual(guard.path, second_guard.path)
                self.assertTrue(
                    guard.path.name.endswith(
                        "enable_false_step_detection-1.attempted.json"
                    )
                )
                guard_record = json.loads(guard.path.read_text())
                self.assertEqual(
                    guard_record["key"],
                    probe.TARGET_FEATURE_KEY,
                )
                self.assertEqual(
                    guard_record["value"],
                    probe.TARGET_FEATURE_VALUE,
                )
            finally:
                recorder.close()

    def test_absent_walk_detector_guard_is_independent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            absent_guard = directory / (
                f"{PERIPHERAL.lower()}-"
                "enable_sigproc_walk_detector-1.attempted.json"
            )
            absent_guard.write_text("{}\n")
            guard = probe.DurableSetAttemptGuard(directory, PERIPHERAL)
            self.assertNotEqual(guard.path, absent_guard)
            guard.claim()
            self.assertTrue(absent_guard.exists())
            self.assertTrue(guard.path.exists())


class OperatorCueTests(unittest.IsolatedAsyncioTestCase):
    async def test_macos_say_uses_exact_shell_free_fixed_argv(self) -> None:
        class FakeProcess:
            def __init__(self) -> None:
                self.returncode: int | None = None

            async def wait(self) -> int:
                self.returncode = 0
                return 0

            def kill(self) -> None:
                self.returncode = -9

        process = FakeProcess()
        spawn = mock.AsyncMock(return_value=process)
        with (
            mock.patch.object(probe.sys, "platform", "darwin"),
            mock.patch.object(probe.Path, "is_file", return_value=True),
            mock.patch.object(probe.os, "access", return_value=True),
            mock.patch.object(
                probe.asyncio,
                "create_subprocess_exec",
                new=spawn,
            ),
        ):
            await probe.macos_say_operator_cue(
                probe.OPERATOR_PHASE_CUES["positive_walk"]
            )

        spawn.assert_awaited_once_with(
            "/usr/bin/say",
            "Walk now.",
            stdin=probe.asyncio.subprocess.DEVNULL,
            stdout=probe.asyncio.subprocess.DEVNULL,
            stderr=probe.asyncio.subprocess.DEVNULL,
        )
        with self.assertRaises(probe.ProbeRefusal):
            await probe.macos_say_operator_cue(
                "user_walk_label_must_not_be_spoken"
            )

    async def test_macos_say_missing_or_nonzero_fails_closed(self) -> None:
        with (
            mock.patch.object(probe.sys, "platform", "darwin"),
            mock.patch.object(probe.Path, "is_file", return_value=False),
            self.assertRaises(probe.ProbeTransportError),
        ):
            await probe.macos_say_operator_cue(
                probe.OPERATOR_CUE_READY_CHECK
            )

        class FailedProcess:
            returncode: int | None = None

            async def wait(self) -> int:
                self.returncode = 7
                return 7

            def kill(self) -> None:
                self.returncode = -9

        with (
            mock.patch.object(probe.sys, "platform", "darwin"),
            mock.patch.object(probe.Path, "is_file", return_value=True),
            mock.patch.object(probe.os, "access", return_value=True),
            mock.patch.object(
                probe.asyncio,
                "create_subprocess_exec",
                new=mock.AsyncMock(return_value=FailedProcess()),
            ),
            self.assertRaises(probe.ProbeTransportError),
        ):
            await probe.preflight_operator_cue(
                probe.macos_say_operator_cue
            )

    async def test_ready_check_failure_precedes_bluetooth_and_artifacts(
        self,
    ) -> None:
        calls: list[str] = []

        async def failed_cue(cue_text: str) -> None:
            calls.append(cue_text)
            raise RuntimeError("offline injected failure")

        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary) / "not-created"
            plan = probe.validate_plan(
                action="enable",
                peripheral_id=PERIPHERAL,
                output_dir=output_dir,
                baseline_seconds=0.0,
                post_seconds=0.0,
                response_timeout_seconds=5.0,
                unknown_state_ack=probe.UNKNOWN_STATE_ACK,
                persistent_write_ack=probe.PERSISTENT_WRITE_ACK,
                positive_walk_label="walk",
                arm_motion_control_label="control",
                banked_discovery=True,
                operator_cues=True,
            )
            with self.assertRaises(probe.ProbeTransportError):
                await probe.run_probe(plan, operator_cue=failed_cue)
            self.assertEqual(calls, [probe.OPERATOR_CUE_READY_CHECK])
            self.assertFalse(output_dir.exists())

    async def test_cue_timeout_fails_closed(self) -> None:
        async def hung_cue(_: str) -> None:
            await asyncio.sleep(60)

        with mock.patch.object(
            probe, "OPERATOR_CUE_TIMEOUT_SECONDS", 0.001
        ):
            with self.assertRaises(probe.ProbeTransportError):
                await probe.preflight_operator_cue(hung_cue)

    async def test_each_fixed_cue_completes_before_phase_and_timestamp(
        self,
    ) -> None:
        events: list[tuple[str, str]] = []

        class FakeRecorder:
            def set_phase(self, phase: str) -> None:
                events.append(("phase", phase))

        async def cue(cue_text: str) -> None:
            events.append(("cue", cue_text))

        async def no_sleep(_: float) -> None:
            events.append(("sleep", ""))

        clock_value = 1000.0

        def now() -> float:
            nonlocal clock_value
            clock_value += 1
            events.append(("time", ""))
            return clock_value

        with (
            mock.patch.object(probe.asyncio, "sleep", new=no_sleep),
            mock.patch.object(probe.time, "time", new=now),
            mock.patch.object(probe.sys, "stderr", new=io.StringIO()),
        ):
            result = await probe.observe_short_activity_sequence(
                FakeRecorder(),  # type: ignore[arg-type]
                quiet_seconds=0,
                positive_walk_seconds=0,
                arm_motion_control_seconds=0,
                positive_walk_label="secret-user-walk-label",
                arm_motion_control_label="secret-user-control-label",
                operator_cue=cue,
            )

        phases = [row["phase"] for row in result]
        self.assertEqual(
            phases,
            [
                f"post_enable_{activity}"
                for activity in probe.OPERATOR_PHASE_CUES
            ],
        )
        cue_texts = [value for kind, value in events if kind == "cue"]
        self.assertEqual(
            cue_texts,
            [
                probe.OPERATOR_BOUNDARY_CUES["post_enable"],
                *probe.OPERATOR_PHASE_CUES.values(),
            ],
        )
        self.assertNotIn("secret-user-walk-label", cue_texts)
        self.assertNotIn("secret-user-control-label", cue_texts)
        for phase, activity in zip(
            phases, probe.OPERATOR_PHASE_CUES, strict=True
        ):
            phase_index = events.index(("phase", phase))
            self.assertEqual(
                events[phase_index - 1],
                ("cue", probe.OPERATOR_PHASE_CUES[activity]),
            )
            time_index = next(
                index
                for index in range(phase_index + 1, len(events))
                if events[index][0] == "time"
            )
            self.assertLess(phase_index, time_index)
        first_phase_index = events.index(("phase", phases[0]))
        boundary_index = events.index(
            ("cue", probe.OPERATOR_BOUNDARY_CUES["post_enable"])
        )
        self.assertLess(boundary_index, first_phase_index)

    async def test_matched_trial_orders_pre_single_set_then_post(self) -> None:
        events: list[tuple[str, str]] = []
        writes: list[bytes] = []

        class FakeRecorder:
            def set_phase(self, phase: str) -> None:
                events.append(("phase", phase))

        async def cue(cue_text: str) -> None:
            events.append(("cue", cue_text))

        async def no_sleep(_: float) -> None:
            events.append(("sleep", ""))

        async def persistent_set() -> dict[str, object]:
            events.append(("set", "0x78"))
            writes.append(
                probe.command_frame(
                    probe.SET_FF_VALUE,
                    probe.TARGET_SET_PAYLOAD,
                    1,
                )
            )
            return {"status": "test_exactly_once"}

        clock_value = 2000.0

        def now() -> float:
            nonlocal clock_value
            clock_value += 1
            events.append(("time", ""))
            return clock_value

        with (
            mock.patch.object(probe.asyncio, "sleep", new=no_sleep),
            mock.patch.object(probe.time, "time", new=now),
            mock.patch.object(probe.sys, "stderr", new=io.StringIO()),
        ):
            trial = await probe.observe_matched_enable_trial(
                FakeRecorder(),  # type: ignore[arg-type]
                persistent_set_action=persistent_set,
                quiet_seconds=0,
                positive_walk_seconds=0,
                arm_motion_control_seconds=0,
                positive_walk_label="externally-reported-walk",
                arm_motion_control_label="externally-reported-control",
                operator_cue=cue,
            )

        pre_phases = [
            f"pre_enable_{activity}"
            for activity in probe.ACTIVITY_SEQUENCE_STAGES
        ]
        post_phases = [
            f"post_enable_{activity}"
            for activity in probe.ACTIVITY_SEQUENCE_STAGES
        ]
        self.assertEqual(
            [row["phase"] for row in trial["preEnable"]],
            pre_phases,
        )
        self.assertEqual(
            [row["phase"] for row in trial["postEnable"]],
            post_phases,
        )
        self.assertEqual(
            [row["phase"] for row in trial["combinedPhases"]],
            [*pre_phases, *post_phases],
        )
        self.assertEqual(
            [
                row["operatorLabelTruth"]
                for row in trial["combinedPhases"]
            ],
            [
                "planned_or_externally_reported_not_verified_by_harness"
            ]
            * 10,
        )
        self.assertTrue(
            all(
                not row["activityVerifiedByHarness"]
                for row in trial["combinedPhases"]
            )
        )
        set_indices = [
            index
            for index, event in enumerate(events)
            if event == ("set", "0x78")
        ]
        self.assertEqual(len(set_indices), 1)
        set_index = set_indices[0]
        self.assertLess(
            events.index(("phase", pre_phases[-1])),
            set_index,
        )
        self.assertLess(
            set_index,
            events.index(
                ("cue", probe.OPERATOR_BOUNDARY_CUES["post_enable"])
            ),
        )
        for prefix, phases in (
            ("pre_enable", pre_phases),
            ("post_enable", post_phases),
        ):
            boundary_index = events.index(
                ("cue", probe.OPERATOR_BOUNDARY_CUES[prefix])
            )
            first_phase_index = events.index(("phase", phases[0]))
            first_time_index = next(
                index
                for index in range(first_phase_index + 1, len(events))
                if events[index][0] == "time"
            )
            self.assertLess(boundary_index, first_phase_index)
            self.assertLess(first_phase_index, first_time_index)
        self.assertEqual(len(writes), 1)
        self.assertEqual(
            probe.frame_inner(writes[0])[2],
            probe.SET_FF_VALUE,
        )
        self.assertEqual(probe.ALLOWED_OPCODES, {0x75, 0x76, 0x78})
        self.assertEqual(
            probe.HISTORY_OBSERVATION_OPCODES,
            {0x22, 0x16, 0x14},
        )

    def test_cli_flag_and_plan_authority_are_enable_only(self) -> None:
        parser = probe.build_parser()
        args, unknown = parser.parse_known_args(
            [
                "enable",
                "--peripheral-id",
                PERIPHERAL,
                "--output-dir",
                "/tmp/whoop-probe-cue-test",
                "--positive-walk-label",
                "walk",
                "--arm-motion-control-label",
                "control",
                "--operator-cues",
                "--banked-discovery",
            ]
        )
        self.assertEqual(unknown, [])
        self.assertTrue(args.operator_cues)
        without_cues = [
            "enable",
            "--peripheral-id",
            PERIPHERAL,
            "--output-dir",
            "/tmp/whoop-probe-cue-test",
            "--positive-walk-label",
            "walk",
            "--arm-motion-control-label",
            "control",
            "--banked-discovery",
        ]
        with (
            mock.patch.object(probe.sys, "stderr", new=io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            parser.parse_args(without_cues)

        _, enumeration_unknown = parser.parse_known_args(
            [
                "enumerate",
                "--peripheral-id",
                PERIPHERAL,
                "--output-dir",
                "/tmp/whoop-probe-cue-test",
                "--operator-cues",
            ]
        )
        self.assertEqual(enumeration_unknown, ["--operator-cues"])
        with self.assertRaises(probe.ProbeRefusal):
            probe.validate_plan(
                action="enumerate",
                peripheral_id=PERIPHERAL,
                output_dir=Path("/tmp/whoop-probe-cue-test"),
                baseline_seconds=0,
                post_seconds=0,
                response_timeout_seconds=5,
                operator_cues=True,
            )


class PinnedEnumerationRunOrderTests(unittest.IsolatedAsyncioTestCase):
    async def test_bad_pinned_artifact_refuses_before_cues_or_bluetooth(
        self,
    ) -> None:
        cue_calls: list[str] = []

        async def cue(text: str) -> None:
            cue_calls.append(text)

        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary) / "output"
            plan = probe.validate_plan(
                action="enable",
                peripheral_id=PERIPHERAL,
                output_dir=output_dir,
                baseline_seconds=0,
                post_seconds=0,
                response_timeout_seconds=5,
                unknown_state_ack=probe.UNKNOWN_STATE_ACK,
                persistent_write_ack=probe.PERSISTENT_WRITE_ACK,
                positive_walk_label="counted_walk",
                arm_motion_control_label="planted_feet_control",
                banked_discovery=True,
                operator_cues=True,
            )
            with (
                mock.patch.object(
                    probe,
                    "verify_pinned_enumeration_evidence",
                    side_effect=probe.ProbeRefusal("bad pinned artifact"),
                ),
                self.assertRaisesRegex(
                    probe.ProbeRefusal,
                    "bad pinned artifact",
                ),
            ):
                await probe.run_probe(plan, operator_cue=cue)
            self.assertEqual(cue_calls, [])
            self.assertFalse(output_dir.exists())

    async def test_snapshot_mismatch_refuses_before_range_or_guard(
        self,
    ) -> None:
        history_preflight_calls = 0

        class FakeScanner:
            @staticmethod
            async def find_device_by_address(
                address: str, timeout: float
            ) -> object:
                del timeout
                return types.SimpleNamespace(address=address)

        class FakeClient:
            def __init__(self, device: object) -> None:
                self.address = device.address

            async def __aenter__(self) -> "FakeClient":
                return self

            async def __aexit__(
                self,
                exception_type: object,
                exception: object,
                traceback: object,
            ) -> None:
                del exception_type, exception, traceback

            async def start_notify(
                self, characteristic: str, handler: object
            ) -> None:
                del characteristic, handler

        class FakeChannel:
            def __init__(
                self,
                client: object,
                recorder: object,
                **_: object,
            ) -> None:
                del client, recorder
                self.set_write_attempted = False
                self.history_trace: list[int] = []

            def receive_frames(self, frames: list[bytes]) -> None:
                del frames

            async def call_data_range(
                self, *, timeout_seconds: float
            ) -> probe.DataRangeCursor:
                nonlocal history_preflight_calls
                del timeout_seconds
                history_preflight_calls += 1
                raise AssertionError("0x22 must be unreachable")

        async def mismatched_enumeration(
            channel: object, timeout_seconds: float
        ) -> tuple[probe.FeatureFlagStart, list[probe.FeatureFlagEntry]]:
            del channel, timeout_seconds
            entries = pinned_entries()
            entries[0], entries[1] = entries[1], entries[0]
            return (
                probe.FeatureFlagStart(
                    revision=probe.PINNED_ENUMERATION_REVISION,
                    count=len(probe.PINNED_ENUMERATION_KEYS),
                ),
                entries,
            )

        async def cue(_: str) -> None:
            return None

        fake_bleak = types.ModuleType("bleak")
        fake_bleak.BleakClient = FakeClient
        fake_bleak.BleakScanner = FakeScanner
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output_dir = root / "output"
            attempt_dir = root / "attempts"
            plan = probe.validate_plan(
                action="enable",
                peripheral_id=PERIPHERAL,
                output_dir=output_dir,
                baseline_seconds=0,
                post_seconds=0,
                response_timeout_seconds=5,
                unknown_state_ack=probe.UNKNOWN_STATE_ACK,
                persistent_write_ack=probe.PERSISTENT_WRITE_ACK,
                positive_walk_label="counted_walk",
                arm_motion_control_label="planted_feet_control",
                banked_discovery=True,
                operator_cues=True,
            )
            with (
                mock.patch.dict(probe.sys.modules, {"bleak": fake_bleak}),
                mock.patch.object(probe, "CommandChannel", FakeChannel),
                mock.patch.object(
                    probe,
                    "enumerate_feature_keys",
                    new=mismatched_enumeration,
                ),
                mock.patch.object(
                    probe,
                    "DEFAULT_ATTEMPT_GUARD_DIRECTORY",
                    attempt_dir,
                ),
                self.assertRaises(probe.ProbeRefusal),
            ):
                await probe.run_probe(plan, operator_cue=cue)

            self.assertEqual(history_preflight_calls, 0)
            self.assertFalse(attempt_dir.exists())
            manifests = list(output_dir.glob("*-manifest.json"))
            self.assertEqual(len(manifests), 1)
            manifest = json.loads(manifests[0].read_text())
            self.assertFalse(manifest["setWriteAttempted"])
            self.assertFalse(
                manifest["pinnedPhysicalEnumeration"][
                    "sameRunSnapshotVerified"
                ]
            )


class ProbeCueFailurePersistenceTests(unittest.IsolatedAsyncioTestCase):
    async def _run_with_failed_cue(
        self,
        temporary: str,
        failed_cue_text: str,
    ) -> tuple[dict[str, object], list[int], list[str], list[float], Path]:
        output_dir = Path(temporary) / "output"
        attempt_directory = Path(temporary) / "attempts"
        set_calls: list[int] = []
        cue_calls: list[str] = []
        sleep_calls: list[float] = []
        test_case = self

        class FakeScanner:
            @staticmethod
            async def find_device_by_address(
                address: str, timeout: float
            ) -> object:
                del timeout
                return types.SimpleNamespace(address=address)

        class FakeClient:
            def __init__(self, device: object) -> None:
                self.address = device.address

            async def __aenter__(self) -> "FakeClient":
                return self

            async def __aexit__(
                self,
                exception_type: object,
                exception: object,
                traceback: object,
            ) -> None:
                del exception_type, exception, traceback

            async def start_notify(
                self, characteristic: str, handler: object
            ) -> None:
                del characteristic, handler

        class FakeChannel:
            def __init__(
                self,
                client: object,
                recorder: object,
                *,
                persistent_write_authorized: bool = False,
                empty_history_preflight_required: bool = False,
                persistent_attempt_guard: object = None,
            ) -> None:
                del client, recorder
                self.set_write_attempted = False
                self.history_trace: list[int] = []
                self.persistent_write_authorized = (
                    persistent_write_authorized
                )
                self.empty_history_preflight_required = (
                    empty_history_preflight_required
                )
                self.persistent_attempt_guard = persistent_attempt_guard

            def receive_frames(self, frames: list[bytes]) -> None:
                del frames

            async def call_data_range(
                self, *, timeout_seconds: float
            ) -> probe.DataRangeCursor:
                del timeout_seconds
                self.history_trace.append(probe.GET_DATA_RANGE)
                return probe.DataRangeCursor(
                    write_cursor=10,
                    read_cursor=10,
                    capacity=131_072,
                    device_unix=1_785_000_000,
                )

            def authorize_after_empty_history_preflight(
                self, cursor: probe.DataRangeCursor
            ) -> None:
                probe.require_empty_history_preflight(cursor)
                self.persistent_write_authorized = True

            async def call(
                self,
                opcode: int,
                payload: bytes,
                timeout_seconds: float,
            ) -> bytes:
                del timeout_seconds
                test_case.assertEqual(opcode, probe.SET_FF_VALUE)
                test_case.assertEqual(payload, probe.TARGET_SET_PAYLOAD)
                test_case.assertTrue(self.persistent_write_authorized)
                test_case.assertFalse(self.set_write_attempted)
                test_case.assertIsNotNone(self.persistent_attempt_guard)
                self.persistent_attempt_guard()
                self.set_write_attempted = True
                set_calls.append(opcode)
                return bytes(
                    (
                        probe.COMMAND_RESPONSE_PACKET_TYPE,
                        1,
                        probe.SET_FF_VALUE,
                        1,
                        0x01,
                    )
                ) + probe.TARGET_SET_PAYLOAD

        async def fake_enumeration(
            channel: object, timeout_seconds: float
        ) -> tuple[probe.FeatureFlagStart, list[probe.FeatureFlagEntry]]:
            del channel, timeout_seconds
            return (
                probe.FeatureFlagStart(
                    revision=probe.PINNED_ENUMERATION_REVISION,
                    count=len(probe.PINNED_ENUMERATION_KEYS),
                ),
                pinned_entries(),
            )

        async def cue(cue_text: str) -> None:
            cue_calls.append(cue_text)
            if cue_text == failed_cue_text:
                raise RuntimeError("injected cue failure")

        async def no_sleep(duration: float) -> None:
            sleep_calls.append(duration)

        fake_bleak = types.ModuleType("bleak")
        fake_bleak.BleakClient = FakeClient
        fake_bleak.BleakScanner = FakeScanner
        plan = probe.validate_plan(
            action="enable",
            peripheral_id=PERIPHERAL,
            output_dir=output_dir,
            baseline_seconds=0,
            post_seconds=0,
            response_timeout_seconds=5,
            unknown_state_ack=probe.UNKNOWN_STATE_ACK,
            persistent_write_ack=probe.PERSISTENT_WRITE_ACK,
            positive_walk_label="reported_walk",
            arm_motion_control_label="reported_control",
            banked_discovery=True,
            operator_cues=True,
        )
        with (
            mock.patch.dict(probe.sys.modules, {"bleak": fake_bleak}),
            mock.patch.object(probe, "CommandChannel", FakeChannel),
            mock.patch.object(
                probe,
                "enumerate_feature_keys",
                new=fake_enumeration,
            ),
            mock.patch.object(probe.asyncio, "sleep", new=no_sleep),
            mock.patch.object(
                probe,
                "DEFAULT_ATTEMPT_GUARD_DIRECTORY",
                attempt_directory,
            ),
            mock.patch.object(probe.sys, "stderr", new=io.StringIO()),
            self.assertRaises(probe.ProbeTransportError),
        ):
            await probe.run_probe(plan, operator_cue=cue)

        manifest_paths = list(output_dir.glob("*-manifest.json"))
        self.assertEqual(len(manifest_paths), 1)
        manifest = json.loads(manifest_paths[0].read_text())
        return manifest, set_calls, cue_calls, sleep_calls, attempt_directory

    async def test_pre_enable_cue_failure_never_claims_set_attempt(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest, set_calls, cue_calls, sleep_calls, attempt_directory = (
                await self._run_with_failed_cue(
                    temporary,
                    probe.OPERATOR_BOUNDARY_CUES["pre_enable"],
                )
            )
            self.assertEqual(set_calls, [])
            self.assertEqual(
                cue_calls,
                [
                    probe.OPERATOR_CUE_READY_CHECK,
                    probe.OPERATOR_BOUNDARY_CUES["pre_enable"],
                ],
            )
            self.assertEqual(
                sleep_calls,
                [probe.POST_RANGE_RESPONSE_SETTLE_SECONDS],
            )
            self.assertEqual(
                probe.POST_RANGE_RESPONSE_SETTLE_SECONDS,
                2.0,
            )
            self.assertFalse(manifest["setWriteAttempted"])
            self.assertNotIn("persistentWrite", manifest)
            self.assertEqual(manifest["status"], "failed")
            self.assertFalse(
                manifest["labelledActivityComparison"][
                    "featureEffectClaimed"
                ]
            )
            self.assertFalse(attempt_directory.exists())

    async def test_post_enable_cue_failure_preserves_one_shot_status(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest, set_calls, cue_calls, sleep_calls, attempt_directory = (
                await self._run_with_failed_cue(
                    temporary,
                    probe.OPERATOR_BOUNDARY_CUES["post_enable"],
                )
            )
            self.assertEqual(set_calls, [probe.SET_FF_VALUE])
            self.assertEqual(
                cue_calls[-1],
                probe.OPERATOR_BOUNDARY_CUES["post_enable"],
            )
            self.assertEqual(
                sleep_calls[0],
                probe.POST_RANGE_RESPONSE_SETTLE_SECONDS,
            )
            self.assertTrue(manifest["setWriteAttempted"])
            persistent = manifest["persistentWrite"]
            self.assertTrue(persistent["attemptedExactlyOnce"])
            self.assertEqual(
                persistent["status"],
                "exact_target_echo_observed_no_effect_claim",
            )
            self.assertFalse(persistent["effectSuccessClaimed"])
            self.assertEqual(manifest["status"], "failed")
            self.assertFalse(
                manifest["labelledActivityComparison"][
                    "featureEffectClaimed"
                ]
            )
            attempts = list(attempt_directory.glob("*.attempted.json"))
            self.assertEqual(len(attempts), 1)


class OptInPlanTests(unittest.TestCase):
    def valid_enable(self, **overrides: object) -> probe.ProbePlan:
        values = {
            "action": "enable",
            "peripheral_id": PERIPHERAL,
            "output_dir": Path("/tmp/whoop-probe-test"),
            "baseline_seconds": 0.0,
            "post_seconds": 0.0,
            "response_timeout_seconds": 5.0,
            "unknown_state_ack": probe.UNKNOWN_STATE_ACK,
            "persistent_write_ack": probe.PERSISTENT_WRITE_ACK,
            "positive_walk_label": "counted_walk_500",
            "arm_motion_control_label": "planted_feet_arm_control",
            "banked_discovery": True,
            "operator_cues": True,
        }
        values.update(overrides)
        return probe.validate_plan(**values)

    def test_enable_requires_both_exact_acknowledgements(self) -> None:
        plan = self.valid_enable()
        self.assertTrue(plan.allows_persistent_write)
        for first, second in (
            (None, probe.PERSISTENT_WRITE_ACK),
            (probe.UNKNOWN_STATE_ACK, None),
            ("I accept", probe.PERSISTENT_WRITE_ACK),
            (probe.UNKNOWN_STATE_ACK, "yes"),
        ):
            with self.assertRaises(probe.ProbeRefusal):
                self.valid_enable(
                    unknown_state_ack=first,
                    persistent_write_ack=second,
                )

    def test_enable_requires_fixed_cues_and_pinned_peripheral(self) -> None:
        with self.assertRaisesRegex(
            probe.ProbeRefusal,
            "requires fixed operator cues",
        ):
            self.valid_enable(operator_cues=False)
        with self.assertRaisesRegex(
            probe.ProbeRefusal,
            "pinned to the exact CoreBluetooth UUID",
        ):
            self.valid_enable(peripheral_id=OTHER_PERIPHERAL)

        enumeration = probe.validate_plan(
            action="enumerate",
            peripheral_id=OTHER_PERIPHERAL,
            output_dir=Path("/tmp/whoop-enumeration-only"),
            baseline_seconds=0,
            post_seconds=0,
            response_timeout_seconds=5,
        )
        self.assertFalse(enumeration.allows_persistent_write)

    def test_enable_without_banked_discovery_is_refused(self) -> None:
        with self.assertRaisesRegex(
            probe.ProbeRefusal,
            "requires the banked-discovery safety firewall",
        ):
            self.valid_enable(banked_discovery=False)

        with tempfile.TemporaryDirectory() as temporary:
            unsafe_plan = replace(
                self.valid_enable(output_dir=Path(temporary)),
                banked_discovery=None,
            )
            self.assertFalse(unsafe_plan.allows_persistent_write)
            with self.assertRaisesRegex(
                probe.ProbeRefusal,
                "requires the banked-discovery safety firewall",
            ):
                asyncio.run(probe.run_probe(unsafe_plan))
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_enable_refuses_legacy_long_windows_and_unbounded_phases(self) -> None:
        with self.assertRaises(probe.ProbeRefusal):
            self.valid_enable(baseline_seconds=1)
        with self.assertRaises(probe.ProbeRefusal):
            self.valid_enable(post_seconds=1)
        with self.assertRaises(probe.ProbeRefusal):
            self.valid_enable(quiet_phase_seconds=6)
        with self.assertRaises(probe.ProbeRefusal):
            self.valid_enable(positive_walk_seconds=9)
        with self.assertRaises(probe.ProbeRefusal):
            self.valid_enable(arm_motion_control_seconds=13)

    def test_nonfinite_durations_and_timeouts_fail_closed(self) -> None:
        for field in (
            "response_timeout_seconds",
            "quiet_phase_seconds",
            "positive_walk_seconds",
            "arm_motion_control_seconds",
            "history_observation_seconds",
        ):
            with self.subTest(field=field):
                with self.assertRaises(probe.ProbeRefusal):
                    self.valid_enable(
                        banked_discovery=True,
                        **{field: float("nan")},
                    )

    def test_enable_requires_two_distinct_explicit_activity_labels(self) -> None:
        for walk, control in (
            (None, "control"),
            ("walk", None),
            ("", "control"),
            ("same", "same"),
        ):
            with self.assertRaises(probe.ProbeRefusal):
                self.valid_enable(
                    positive_walk_label=walk,
                    arm_motion_control_label=control,
                )

    def test_enumeration_does_not_gain_write_authority(self) -> None:
        plan = probe.validate_plan(
            action="enumerate",
            peripheral_id=PERIPHERAL.lower(),
            output_dir=Path("/tmp/whoop-probe-test"),
            baseline_seconds=0,
            post_seconds=0,
            response_timeout_seconds=5,
            unknown_state_ack=probe.UNKNOWN_STATE_ACK,
            persistent_write_ack=probe.PERSISTENT_WRITE_ACK,
        )
        self.assertEqual(plan.peripheral_id, PERIPHERAL)
        self.assertFalse(plan.allows_persistent_write)
        self.assertEqual(
            probe._manifest(plan)["allowedOpcodes"],
            ["0x75", "0x76"],
        )

    def test_peripheral_must_be_exact_uuid(self) -> None:
        for identity in (
            "",
            "WHOOP",
            "Adidshaft's Whoop",
            "C125C62E",
        ):
            with self.assertRaises(probe.ProbeRefusal):
                self.valid_enable(peripheral_id=identity)

    def test_unknown_action_is_refused(self) -> None:
        with self.assertRaises(probe.ProbeRefusal):
            self.valid_enable(action="disable")

    def test_banked_discovery_is_bounded_and_enable_only(self) -> None:
        history = {
            "banked_discovery": True,
            "history_observation_seconds": 30.0,
            "history_byte_cap": 1_000_000,
        }
        plan = self.valid_enable(**history)
        self.assertIsNotNone(plan.banked_discovery)
        with self.assertRaises(probe.ProbeRefusal):
            self.valid_enable(
                history_observation_seconds=76,
                banked_discovery=True,
            )

        with self.assertRaises(probe.ProbeRefusal):
            probe.validate_plan(
                action="enumerate",
                peripheral_id=PERIPHERAL,
                output_dir=Path("/tmp/whoop-probe-test"),
                baseline_seconds=0,
                post_seconds=0,
                response_timeout_seconds=5,
                **history,
            )

    def test_manifest_never_claims_rollback_or_flag_effect(self) -> None:
        manifest = probe._manifest(self.valid_enable())
        rollback = manifest["rollbackSemantics"]
        self.assertFalse(rollback["implementedByHarness"])
        self.assertFalse(rollback["priorStateRestored"])
        self.assertFalse(rollback["priorStateRestorePossible"])
        self.assertIsNone(rollback["onlyHonestFutureRollbackState"])
        self.assertFalse(manifest["effectClaimed"])
        pinned = manifest["pinnedPhysicalEnumeration"]
        self.assertEqual(
            pinned["sha256"],
            probe.PINNED_ENUMERATION_EVIDENCE_SHA256,
        )
        self.assertEqual(pinned["peripheralID"], PERIPHERAL)
        self.assertEqual(
            pinned["orderedKeys"],
            list(probe.PINNED_ENUMERATION_KEYS),
        )
        self.assertFalse(pinned["artifactVerified"])
        self.assertFalse(pinned["sameRunSnapshotVerified"])
        self.assertIn("history ACK", manifest["forbiddenOperations"])
        self.assertIn("history trim", manifest["forbiddenOperations"])
        banked = probe._manifest(
            self.valid_enable(banked_discovery=True)
        )["bankedDiscovery"]
        self.assertFalse(banked["exactSelectorSupported"])
        self.assertEqual(banked["servePayloadHex"], "00")
        self.assertTrue(banked["firstFIFOChunkOnly"])
        activity = probe._manifest(self.valid_enable())["activityPhases"]
        self.assertEqual(
            activity["sequenceOrder"],
            ["pre_enable", "post_enable"],
        )
        self.assertEqual(
            activity["order"],
            [
                f"{prefix}_{stage}"
                for prefix in probe.ACTIVITY_SEQUENCE_PREFIXES
                for stage in probe.ACTIVITY_SEQUENCE_STAGES
            ],
        )
        self.assertEqual(
            activity["operatorLabelTruth"],
            "planned_or_externally_reported_not_verified_by_harness",
        )
        self.assertFalse(activity["activityVerifiedByHarness"])


class ComparisonTests(unittest.TestCase):
    def test_silence_and_no_difference_never_claim_success(self) -> None:
        silent = probe.compare_labelled_activity({"rows": []})
        self.assertEqual(
            silent["verdict"], "inconclusive_missing_packets"
        )
        self.assertFalse(silent["featureEffectClaimed"])
        self.assertFalse(silent["silenceIsSuccess"])

        same_row = {
            "characteristic": probe.DATA_FROM_STRAP,
            "packetType": 0x2F,
            "recordVersion": 0x18,
            "recordType": None,
            "innerLength": 96,
            "count": 1,
        }
        unchanged = probe.compare_labelled_activity(
            {
                "rows": [
                    dict(same_row, phase="post_enable_positive_walk"),
                    dict(
                        same_row,
                        phase="post_enable_arm_motion_control",
                    ),
                ]
            }
        )
        self.assertEqual(
            unchanged["verdict"],
            "inconclusive_no_observed_difference",
        )
        self.assertFalse(unchanged["featureEffectClaimed"])

    def test_new_signature_is_only_a_candidate(self) -> None:
        result = probe.compare_labelled_activity(
            {
                "rows": [
                    {
                        "phase": "post_enable_arm_motion_control",
                        "characteristic": probe.DATA_FROM_STRAP,
                        "packetType": 0x2F,
                        "recordVersion": 0x18,
                        "recordType": None,
                        "innerLength": 96,
                        "count": 1,
                    },
                    {
                        "phase": "post_enable_positive_walk",
                        "characteristic": probe.DATA_FROM_STRAP,
                        "packetType": 0x2F,
                        "recordVersion": 0x19,
                        "recordType": None,
                        "innerLength": 100,
                        "count": 1,
                    },
                ]
            }
        )
        self.assertEqual(
            result["verdict"],
            "candidate_difference_observed_requires_decoding",
        )
        self.assertFalse(result["featureEffectClaimed"])


class ResponseDecoderTests(unittest.TestCase):
    def test_start_and_next_decode_from_response_record(self) -> None:
        start = probe.decode_start_response(
            probe.frame_inner(
                response_frame(0x75, bytes((1, 11, 0)))
            )
        )
        self.assertEqual(start, probe.FeatureFlagStart(revision=1, count=11))

        record = (
            bytes((1, 7, 1))
            + b"enable_false_step_detection"
            + b"\x00"
        )
        entry = probe.decode_next_response(
            probe.frame_inner(response_frame(0x76, record))
        )
        self.assertEqual(entry.revision, 1)
        self.assertEqual(entry.index, 7)
        self.assertTrue(entry.valid)
        self.assertEqual(entry.key, probe.TARGET_FEATURE_KEY)

    def test_implausible_count_and_bad_ascii_fail_closed(self) -> None:
        for count in (0, 129, 65535):
            with self.assertRaises(probe.ProbeTransportError):
                probe.decode_start_response(
                    probe.frame_inner(
                        response_frame(
                            0x75, bytes((1, count & 0xFF, count >> 8))
                        )
                    )
                )
        with self.assertRaises(probe.ProbeTransportError):
            probe.decode_next_response(
                probe.frame_inner(
                    response_frame(0x76, bytes((1, 1, 1, 0xFF)))
                )
            )

    def test_response_record_requires_observed_data_prefix(self) -> None:
        record = bytes((1, 11, 0))
        for data_prefix in (0x00, 0x02, 0x0A):
            inner = bytes(
                (
                    probe.COMMAND_RESPONSE_PACKET_TYPE,
                    9,
                    probe.START_FF_KEY_EXCHANGE,
                    0x0A,
                    data_prefix,
                )
            ) + record
            with self.assertRaises(probe.ProbeTransportError):
                probe.decode_start_response(inner)

    def test_set_confirmation_requires_exact_echo(self) -> None:
        key_field = probe.TARGET_FEATURE_KEY.encode().ljust(32, b"\x00")
        value_field = b"1".ljust(32, b"\x00")
        confirmed = probe.frame_inner(
            response_frame(0x78, b"\x01" + key_field + value_field)
        )
        self.assertTrue(probe.set_response_confirms_target(confirmed))

        wrong_value = probe.frame_inner(
            response_frame(0x78, b"\x01" + key_field + b"2".ljust(32, b"\x00"))
        )
        wrong_key = probe.frame_inner(
            response_frame(
                0x78,
                b"\x01"
                + b"enable_r19_packets".ljust(32, b"\x00")
                + value_field,
            )
        )
        self.assertFalse(probe.set_response_confirms_target(wrong_value))
        self.assertFalse(probe.set_response_confirms_target(wrong_key))

        for ambiguous_record in (
            b"\x00" + probe.TARGET_SET_PAYLOAD,
            probe.TARGET_SET_PAYLOAD + b"\x00",
            b"\x00" + probe.TARGET_SET_PAYLOAD + b"\x00",
        ):
            ambiguous = probe.frame_inner(
                response_frame(0x78, ambiguous_record)
            )
            self.assertFalse(probe.set_response_confirms_target(ambiguous))

        bad_prefix = bytearray(
            response_frame(0x78, probe.TARGET_SET_PAYLOAD)
        )
        bad_inner = bytearray(probe.frame_inner(bytes(bad_prefix)))
        bad_inner[4] = 0
        self.assertFalse(probe.set_response_confirms_target(bytes(bad_inner)))


class CorpusRecorderTests(unittest.TestCase):
    def test_reassembles_and_summarizes_versions_and_lengths_by_phase(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "corpus.jsonl"
            recorder = probe.CorpusRecorder(path, now=lambda: 1234.5)
            try:
                v19_inner = bytes((0x2F, 0x13, 0x00)) + bytes(73)
                v19 = self._frame(v19_inner)
                v24_inner = bytes((0x2F, 0x18, 0x00)) + bytes(93)
                v24 = self._frame(v24_inner)

                recorder.set_phase("before")
                self.assertEqual(
                    recorder.record_notification(
                        probe.DATA_FROM_STRAP, v19[:9]
                    ),
                    [],
                )
                self.assertEqual(
                    len(
                        recorder.record_notification(
                            probe.DATA_FROM_STRAP, v19[9:]
                        )
                    ),
                    1,
                )
                recorder.set_phase("after")
                recorder.record_notification(
                    probe.DATA_FROM_STRAP, v24
                )
                summary = recorder.summary()
            finally:
                recorder.close()

            rows = summary["rows"]
            self.assertEqual(
                {
                    (
                        row["phase"],
                        row["packetType"],
                        row["recordVersion"],
                        row["innerLength"],
                        row["count"],
                    )
                    for row in rows
                },
                {
                    ("before", 0x2F, 0x13, 76, 1),
                    ("after", 0x2F, 0x18, 96, 1),
                },
            )
            logged = [
                json.loads(line)
                for line in path.read_text().splitlines()
            ]
            frame_rows = [
                row for row in logged if row["kind"] == "frame"
            ]
            notification_rows = [
                row for row in logged if row["kind"] == "notification"
            ]
            self.assertEqual(
                [row["recordVersion"] for row in frame_rows],
                [0x13, 0x18],
            )
            self.assertTrue(
                all("innerHex" in row and "frameHex" in row for row in frame_rows)
            )
            self.assertTrue(
                all("notificationHex" in row for row in notification_rows)
            )
            self.assertEqual(
                b"".join(
                    bytes.fromhex(row["notificationHex"])
                    for row in notification_rows
                    if row["phase"] == "before"
                ),
                v19,
            )

    @staticmethod
    def _frame(inner: bytes) -> bytes:
        length = len(inner) + 4
        length_bytes = length.to_bytes(2, "little")
        return (
            b"\xAA"
            + length_bytes
            + bytes((probe.crc8(length_bytes),))
            + inner
            + (zlib.crc32(inner) & 0xFFFFFFFF).to_bytes(4, "little")
        )


if __name__ == "__main__":
    unittest.main()
