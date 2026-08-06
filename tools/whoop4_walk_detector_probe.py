#!/usr/bin/env python3
"""Isolated WHOOP 4 false-step-filter feature probe.

This is a deliberately narrow, research-only harness for one sacrificial
WHOOP 4 strap.  It can:

* enumerate feature-flag key *names* using commands 0x75 and 0x76; and
* after two explicit acknowledgements, send exactly one persistent 0x78 write
  for ``enable_false_step_detection=1``.

It cannot read the prior flag value reliably.  WHOOP 4 physical captures show
that GET_FF_VALUE can return bytes contaminated by a stale shared buffer.
Consequently a persistent set cannot restore the unknown prior state.  The
tool intentionally provides no disable/rollback command.

Safety boundary:

* exact CoreBluetooth peripheral UUID required and checked again after connect;
* feature opcodes are only 0x75, 0x76, and 0x78;
* the only accepted 0x78 key/value is
  ``enable_false_step_detection`` / ASCII ``"1"``;
* the persistent experiment is pinned to one prior read-only physical
  enumeration artifact, one WHOOP 4 peripheral UUID, revision 1, and its exact
  ordered 13-key snapshot;
* the required persistent-set history firewall admits only GET_DATA_RANGE (0x22),
  plain SEND_HISTORICAL (0x16/00), and ABORT (0x14/00) for the first FIFO
  chunk;
  no ACK, trim, rewind, clock, reboot, or mode command is constructible;
* the 0x78 write is attempted at most once and is never retried;
* matched fixed-duration activity sequences are captured immediately before
  and after that sole write, with distinct pre/post phase names;
* every notification admitted before the explicit time/byte stop and every
  valid WHOOP frame within it is recorded losslessly so a new R19/data-product
  lane can be identified.

Bleak is imported only inside ``run_probe``.  Importing this module or running
its unit tests cannot access Bluetooth.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import math
import os
import sys
import time
import uuid
import zlib
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Awaitable, Callable


WHOOP_SERVICE_SUFFIX = "-8d6d-82b8-614a-1c8cb0f8dcc6"
COMMAND_TO_STRAP = "61080002" + WHOOP_SERVICE_SUFFIX
COMMAND_FROM_STRAP = "61080003" + WHOOP_SERVICE_SUFFIX
EVENTS_FROM_STRAP = "61080004" + WHOOP_SERVICE_SUFFIX
DATA_FROM_STRAP = "61080005" + WHOOP_SERVICE_SUFFIX
DIAGNOSTICS_FROM_STRAP = "61080007" + WHOOP_SERVICE_SUFFIX
NOTIFICATION_CHARACTERISTICS = (
    COMMAND_FROM_STRAP,
    EVENTS_FROM_STRAP,
    DATA_FROM_STRAP,
    DIAGNOSTICS_FROM_STRAP,
)

COMMAND_PACKET_TYPE = 0x23
COMMAND_RESPONSE_PACKET_TYPE = 0x24
HISTORICAL_PACKET_TYPE = 0x2F
REALTIME_RAW_PACKET_TYPE = 0x2B

START_FF_KEY_EXCHANGE = 0x75
SEND_NEXT_FF = 0x76
SET_FF_VALUE = 0x78
ALLOWED_OPCODES = frozenset(
    {START_FF_KEY_EXCHANGE, SEND_NEXT_FF, SET_FF_VALUE}
)

GET_DATA_RANGE = 0x22
SEND_HISTORICAL = 0x16
ABORT_HISTORICAL = 0x14
HISTORY_OBSERVATION_OPCODES = frozenset(
    {GET_DATA_RANGE, SEND_HISTORICAL, ABORT_HISTORICAL}
)
ZERO_PAYLOAD = b"\x00"
MAX_HISTORY_OBSERVATION_SECONDS = 75.0
MAX_HISTORY_OBSERVATION_BYTES = 8 * 1024 * 1024
POST_RANGE_RESPONSE_SETTLE_SECONDS = 2.0
POST_ABORT_SETTLE_SECONDS = 0.5
DEFAULT_QUIET_PHASE_SECONDS = 3.0
DEFAULT_ACTIVITY_PHASE_SECONDS = 12.0
MIN_QUIET_PHASE_SECONDS = 2.0
MAX_QUIET_PHASE_SECONDS = 5.0
MIN_ACTIVITY_PHASE_SECONDS = 10.0
MAX_ACTIVITY_PHASE_SECONDS = 12.0
MACOS_SAY_PATH = "/usr/bin/say"
OPERATOR_CUE_TIMEOUT_SECONDS = 5.0
OPERATOR_CUE_READY_CHECK = "Ready."
OPERATOR_BOUNDARY_CUES = {
    "pre_enable": "Baseline trial begins.",
    "post_enable": "Post-write trial begins.",
}
OPERATOR_PHASE_CUES = {
    "quiet_before_walk": "Stay still now.",
    "positive_walk": "Walk now.",
    "quiet_between": "Stay still now.",
    "arm_motion_control": "Keep your feet planted and move your arm now.",
    "quiet_after_control": "Stay still now.",
}
FIXED_OPERATOR_CUE_TEXTS = frozenset(
    {
        OPERATOR_CUE_READY_CHECK,
        *OPERATOR_BOUNDARY_CUES.values(),
        *OPERATOR_PHASE_CUES.values(),
    }
)
ACTIVITY_SEQUENCE_PREFIXES = ("pre_enable", "post_enable")
ACTIVITY_SEQUENCE_STAGES = tuple(OPERATOR_PHASE_CUES)
LABELLED_ACTIVITY_PHASES = tuple(
    f"{prefix}_{activity}"
    for prefix in ACTIVITY_SEQUENCE_PREFIXES
    for activity in ("positive_walk", "arm_motion_control")
)
OperatorCue = Callable[[str], Awaitable[None]]
PersistentSetAction = Callable[[], Awaitable[dict[str, Any]]]

TARGET_FEATURE_KEY = "enable_false_step_detection"
TARGET_FEATURE_VALUE = "1"
FEATURE_FIELD_BYTES = 32
ENUMERATION_PAYLOAD = b"\x01"
MAX_ENUMERATED_FLAGS = 128
MAX_FRAME_BYTES = 16 * 1024
MAX_OBSERVATION_SECONDS = 2 * 60 * 60
MAX_ACTIVITY_LABEL_BYTES = 120
DEFAULT_ATTEMPT_GUARD_DIRECTORY = (
    Path.home() / ".atria-whoop4-present-flag-attempts"
)

UNKNOWN_STATE_ACK = "UNKNOWN PRIOR STATE CANNOT BE RESTORED"
PERSISTENT_WRITE_ACK = "SET ONLY enable_false_step_detection=1"

PINNED_ENUMERATION_EVIDENCE_PATH = (
    Path(__file__).resolve().parent.parent
    / "evidence"
    / "2026-07-30-native-walk-detector-readonly-enumeration-v4"
    / "walk-detector-20260730T050346Z-manifest.json"
)
PINNED_ENUMERATION_EVIDENCE_SHA256 = (
    "78a73f07c2dc2e9544c8efe1d3cad047a92094b0b849df2c473705d2b3de7c4d"
)
PINNED_PERIPHERAL_ID = "837560C0-5B6C-C520-95EF-B1E713358D33"
PINNED_ENUMERATION_REVISION = 1
PINNED_ENUMERATION_KEYS = (
    "general_ab_test",
    "sigproc_10_sec_dp",
    "enable_r19_packets",
    "enable_r19_v2_packets",
    "enable_r19_v3_packets",
    "enable_r19_v4_packets",
    "enable_r19_v5_packets",
    "enable_r19_v6_packets",
    "enable_write_r24_packets",
    "enable_write_r25_packets",
    "enable_capsense_wear_detect",
    "enable_false_step_detection",
    "wear_detect_bias",
)


class ProbeRefusal(ValueError):
    """The requested operation is outside the harness safety contract."""


class ProbeTransportError(RuntimeError):
    """A Bluetooth or response failure occurred after safety validation."""


@dataclass(frozen=True)
class BankedDiscoveryObservation:
    timeout_seconds: float
    byte_cap: int


@dataclass(frozen=True)
class DataRangeCursor:
    write_cursor: int
    read_cursor: int
    capacity: int
    device_unix: int


@dataclass(frozen=True)
class ProbePlan:
    action: str
    peripheral_id: str
    output_dir: Path
    baseline_seconds: float
    post_seconds: float
    response_timeout_seconds: float
    unknown_state_acknowledged: bool
    persistent_write_authorized: bool
    positive_walk_label: str | None
    arm_motion_control_label: str | None
    quiet_phase_seconds: float
    positive_walk_seconds: float
    arm_motion_control_seconds: float
    banked_discovery: BankedDiscoveryObservation | None
    operator_cues_enabled: bool

    @property
    def allows_persistent_write(self) -> bool:
        return (
            self.action == "enable"
            and self.unknown_state_acknowledged
            and self.persistent_write_authorized
            and self.banked_discovery is not None
        )


@dataclass(frozen=True)
class FeatureFlagStart:
    revision: int
    count: int


@dataclass(frozen=True)
class FeatureFlagEntry:
    revision: int
    index: int
    valid: bool
    key: str | None


class DurableSetAttemptGuard:
    """Crash-durable, per-strap proof that the sole 0x78 was already attempted."""

    def __init__(self, directory: Path, peripheral_id: str) -> None:
        self.directory = directory
        self.peripheral_id = canonical_peripheral_id(peripheral_id)
        self.path = directory / (
            f"{self.peripheral_id.lower()}-"
            "enable_false_step_detection-1.attempted.json"
        )
        self.claimed = False

    def claim(self) -> None:
        if self.claimed:
            raise ProbeRefusal("persistent 0x78 attempt guard is already claimed")
        self.directory.mkdir(parents=True, exist_ok=True)
        payload = (
            json.dumps(
                {
                    "schema": 1,
                    "peripheralID": self.peripheral_id,
                    "key": TARGET_FEATURE_KEY,
                    "value": TARGET_FEATURE_VALUE,
                    "claimedAt": datetime.now(timezone.utc).isoformat(),
                },
                sort_keys=True,
            )
            + "\n"
        ).encode("utf-8")
        try:
            descriptor = os.open(
                self.path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
        except FileExistsError as error:
            raise ProbeRefusal(
                "a durable record proves this strap/target 0x78 was already "
                f"attempted: {self.path}"
            ) from error

        # Once the exclusive file exists, any failure stays fail-closed. Never
        # remove it: a crash after the BLE write cannot establish whether the
        # strap applied the persistent value.
        self.claimed = True
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            directory_descriptor = os.open(self.directory, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        except Exception:
            raise


def canonical_peripheral_id(raw: str) -> str:
    """Require a CoreBluetooth UUID; names and fuzzy identifiers are forbidden."""

    try:
        return str(uuid.UUID(raw)).upper()
    except (ValueError, AttributeError) as error:
        raise ProbeRefusal(
            "peripheral identity must be one exact CoreBluetooth UUID"
        ) from error


def verify_pinned_enumeration_evidence(
    evidence_path: Path = PINNED_ENUMERATION_EVIDENCE_PATH,
) -> dict[str, Any]:
    """Verify the exact prior read-only artifact that authorizes this experiment."""

    try:
        raw = evidence_path.read_bytes()
    except OSError as error:
        raise ProbeRefusal(
            f"pinned enumeration evidence is unavailable: {evidence_path}"
        ) from error
    digest = hashlib.sha256(raw).hexdigest()
    if digest != PINNED_ENUMERATION_EVIDENCE_SHA256:
        raise ProbeRefusal(
            "pinned enumeration evidence SHA-256 does not match the audited "
            "physical artifact"
        )
    try:
        evidence = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProbeRefusal(
            "pinned enumeration evidence is not valid JSON"
        ) from error
    if not isinstance(evidence, dict):
        raise ProbeRefusal("pinned enumeration evidence is not an object")
    enumeration = evidence.get("enumeration")
    if not isinstance(enumeration, dict):
        raise ProbeRefusal(
            "pinned enumeration evidence has no enumeration object"
        )
    expected_keys = list(PINNED_ENUMERATION_KEYS)
    if (
        evidence.get("peripheralID") != PINNED_PERIPHERAL_ID
        or evidence.get("status") != "capture_completed_evaluation_pending"
        or evidence.get("setWriteAttempted") is not False
        or enumeration.get("revision") != PINNED_ENUMERATION_REVISION
        or enumeration.get("announcedCount") != len(expected_keys)
        or enumeration.get("keys") != expected_keys
    ):
        raise ProbeRefusal(
            "pinned enumeration evidence content does not match the audited "
            "read-only WHOOP 4 snapshot"
        )
    return evidence


async def macos_say_operator_cue(cue_text: str) -> None:
    """Speak one fixed cue with an exact, shell-free macOS ``say`` argv."""

    if cue_text not in FIXED_OPERATOR_CUE_TEXTS:
        raise ProbeRefusal("operator cue text is not fixed by the harness")
    say_path = Path(MACOS_SAY_PATH)
    if (
        sys.platform != "darwin"
        or not say_path.is_file()
        or not os.access(say_path, os.X_OK)
    ):
        raise ProbeTransportError(
            f"operator cues require executable {MACOS_SAY_PATH} on macOS"
        )
    try:
        process = await asyncio.create_subprocess_exec(
            MACOS_SAY_PATH,
            cue_text,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except OSError as error:
        raise ProbeTransportError(
            f"operator cue could not start {MACOS_SAY_PATH}"
        ) from error
    try:
        return_code = await process.wait()
    except asyncio.CancelledError:
        if process.returncode is None:
            process.kill()
            await process.wait()
        raise
    if return_code != 0:
        raise ProbeTransportError(
            f"operator cue {MACOS_SAY_PATH} exited with status {return_code}"
        )


async def deliver_operator_cue(cue: OperatorCue, cue_text: str) -> None:
    """Deliver one allowlisted cue behind the experiment's hard timeout."""

    if cue_text not in FIXED_OPERATOR_CUE_TEXTS:
        raise ProbeRefusal("operator cue text is not fixed by the harness")
    try:
        await asyncio.wait_for(
            cue(cue_text),
            timeout=OPERATOR_CUE_TIMEOUT_SECONDS,
        )
    except asyncio.TimeoutError as error:
        raise ProbeTransportError(
            "operator cue timed out before completing"
        ) from error
    except (ProbeRefusal, ProbeTransportError):
        raise
    except Exception as error:
        raise ProbeTransportError("operator cue failed") from error


async def preflight_operator_cue(cue: OperatorCue) -> None:
    """Prove the cue path with a neutral check before any probe command."""

    await deliver_operator_cue(cue, OPERATOR_CUE_READY_CHECK)


def target_set_payload(key: str, value: str) -> bytes:
    """Build the sole persistent payload this harness is allowed to transmit."""

    if key != TARGET_FEATURE_KEY:
        raise ProbeRefusal(f"feature key is not allowlisted: {key!r}")
    if value != TARGET_FEATURE_VALUE:
        raise ProbeRefusal(
            "only enable_false_step_detection=1 is allowed; any other "
            "values are intentionally unavailable"
        )
    key_bytes = key.encode("ascii")
    value_bytes = value.encode("ascii")
    if len(key_bytes) > FEATURE_FIELD_BYTES or len(value_bytes) > FEATURE_FIELD_BYTES:
        raise ProbeRefusal("feature key/value exceeds the fixed WHOOP field")
    return (
        b"\x01"
        + key_bytes.ljust(FEATURE_FIELD_BYTES, b"\x00")
        + value_bytes.ljust(FEATURE_FIELD_BYTES, b"\x00")
    )


TARGET_SET_PAYLOAD = target_set_payload(
    TARGET_FEATURE_KEY, TARGET_FEATURE_VALUE
)


def crc8(data: bytes) -> int:
    """WHOOP header CRC-8, polynomial 0x07."""

    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (
                ((value << 1) ^ 0x07) & 0xFF
                if value & 0x80
                else (value << 1) & 0xFF
            )
    return value


def validate_command(opcode: int, payload: bytes) -> None:
    """Reject every feature opcode/payload outside the exact experiment."""

    if opcode not in ALLOWED_OPCODES:
        raise ProbeRefusal(f"command opcode is not allowlisted: 0x{opcode:02x}")
    if opcode in (START_FF_KEY_EXCHANGE, SEND_NEXT_FF):
        if payload != ENUMERATION_PAYLOAD:
            raise ProbeRefusal(
                f"0x{opcode:02x} requires the exact read-only payload 01"
            )
        return
    if opcode == SET_FF_VALUE and payload != TARGET_SET_PAYLOAD:
        raise ProbeRefusal(
            "0x78 payload is not the exact false-step-filter experiment payload"
        )


def validate_history_command(opcode: int, payload: bytes) -> None:
    """Admit only 22/00, 16/00, and 14/00; selectors are impossible."""

    if opcode not in HISTORY_OBSERVATION_OPCODES:
        raise ProbeRefusal(
            f"history observation opcode is not allowlisted: 0x{opcode:02x}"
        )
    if payload != ZERO_PAYLOAD:
        raise ProbeRefusal(
            f"history opcode 0x{opcode:02x} requires the exact payload 00"
        )


def _validated_command_frame(
    opcode: int,
    payload: bytes,
    sequence: int,
    validator: Callable[[int, bytes], None],
) -> bytes:
    validator(opcode, payload)
    if not 0 <= sequence <= 0xFF:
        raise ProbeRefusal("command sequence must fit in one byte")
    inner = bytes((COMMAND_PACKET_TYPE, sequence, opcode)) + payload
    length = len(inner) + 4
    length_bytes = length.to_bytes(2, "little")
    return (
        b"\xAA"
        + length_bytes
        + bytes((crc8(length_bytes),))
        + inner
        + (zlib.crc32(inner) & 0xFFFFFFFF).to_bytes(4, "little")
    )


def command_frame(opcode: int, payload: bytes, sequence: int) -> bytes:
    """Frame one safety-validated feature command."""

    return _validated_command_frame(
        opcode, payload, sequence, validate_command
    )


def history_command_frame(
    opcode: int, payload: bytes, sequence: int
) -> bytes:
    """Frame one command behind the separate first-chunk history firewall."""

    return _validated_command_frame(
        opcode,
        payload,
        sequence,
        validate_history_command,
    )


def frame_inner(frame: bytes) -> bytes:
    """Validate both WHOOP CRCs and return the inner packet."""

    if len(frame) < 11 or frame[0] != 0xAA:
        raise ProbeTransportError("invalid WHOOP frame envelope")
    length = int.from_bytes(frame[1:3], "little")
    if length < 7 or len(frame) != length + 4:
        raise ProbeTransportError("invalid WHOOP frame length")
    if crc8(frame[1:3]) != frame[3]:
        raise ProbeTransportError("WHOOP header CRC mismatch")
    inner = frame[4:length]
    expected_crc = int.from_bytes(frame[length : length + 4], "little")
    if (zlib.crc32(inner) & 0xFFFFFFFF) != expected_crc:
        raise ProbeTransportError("WHOOP payload CRC mismatch")
    return inner


def parse_data_range_cursor_frame(frame: bytes) -> DataRangeCursor:
    """Read the physically established W/U/capacity/clock coordinates."""

    inner = frame_inner(frame)
    if len(inner) < 3 or inner[0] != COMMAND_RESPONSE_PACKET_TYPE:
        raise ProbeTransportError("GET_DATA_RANGE reply is not a command response")
    if inner[2] != GET_DATA_RANGE:
        raise ProbeTransportError(
            f"expected GET_DATA_RANGE response, received 0x{inner[2]:02x}"
        )
    # Captured WHOOP 4 replies are:
    # [24,responseSeq,22,requestSeq,01,01,...]
    # with W/U/capacity/deviceUnix at inner offsets 14/18/26/62.
    # A shorter packet cannot establish the clock used to align labelled
    # activity phases and must not unlock the persistent experiment.
    if len(inner) < 66:
        raise ProbeTransportError(
            "GET_DATA_RANGE response is too short for W/U/capacity/clock"
        )
    if inner[4:6] != b"\x01\x01":
        raise ProbeTransportError(
            "GET_DATA_RANGE response lacks the physically observed 01 01 prefix"
        )
    write_cursor = int.from_bytes(inner[14:18], "little")
    read_cursor = int.from_bytes(inner[18:22], "little")
    capacity = int.from_bytes(inner[26:30], "little")
    device_unix = int.from_bytes(inner[62:66], "little")
    if (
        capacity < 1_024
        or capacity > 1_048_576
        or write_cursor >= capacity
        or read_cursor >= capacity
    ):
        raise ProbeTransportError(
            "GET_DATA_RANGE returned implausible ring-buffer coordinates"
        )
    if device_unix <= 0:
        raise ProbeTransportError("GET_DATA_RANGE returned an invalid device clock")
    return DataRangeCursor(
        write_cursor=write_cursor,
        read_cursor=read_cursor,
        capacity=capacity,
        device_unix=device_unix,
    )


def response_record(inner: bytes, expected_opcode: int) -> bytes:
    """Extract a feature record behind its observed one-byte data prefix.

    Command responses are ``24,responseSeq,opcode,requestSeq,data...``.
    Sequence correlation belongs to ``CommandChannel``; feature captures then
    carry an observed ``01`` prefix at ``data[0]`` before the record.
    """

    if len(inner) < 6:
        raise ProbeTransportError("truncated command response")
    if inner[0] != COMMAND_RESPONSE_PACKET_TYPE:
        raise ProbeTransportError("packet is not a command response")
    if inner[2] != expected_opcode:
        raise ProbeTransportError(
            f"response opcode 0x{inner[2]:02x} does not match "
            f"0x{expected_opcode:02x}"
        )
    data = inner[4:]
    if len(data) <= 1:
        raise ProbeTransportError("response has no record after its prefix")
    if data[0] != 0x01:
        raise ProbeTransportError(
            "feature response lacks the physically observed 01 data prefix"
        )
    return data[1:]


def decode_start_response(inner: bytes) -> FeatureFlagStart:
    record = response_record(inner, START_FF_KEY_EXCHANGE)
    if len(record) < 3:
        raise ProbeTransportError("truncated feature-key start response")
    count = int.from_bytes(record[1:3], "little")
    if not 0 < count <= MAX_ENUMERATED_FLAGS:
        raise ProbeTransportError(
            f"implausible feature-key count {count}; refusing enumeration"
        )
    return FeatureFlagStart(revision=record[0], count=count)


def _decode_ascii_key(raw: bytes) -> str | None:
    key_bytes = raw.split(b"\x00", 1)[0]
    if not key_bytes:
        return None
    if len(key_bytes) > FEATURE_FIELD_BYTES:
        raise ProbeTransportError("feature key exceeds the fixed field")
    if any(byte < 0x20 or byte > 0x7E for byte in key_bytes):
        raise ProbeTransportError("feature key is not printable ASCII")
    return key_bytes.decode("ascii")


def decode_next_response(inner: bytes) -> FeatureFlagEntry:
    record = response_record(inner, SEND_NEXT_FF)
    if len(record) < 2:
        raise ProbeTransportError("truncated feature-key entry response")
    valid = len(record) >= 3 and record[2] != 0
    key = _decode_ascii_key(record[3:]) if len(record) >= 4 and valid else None
    return FeatureFlagEntry(
        revision=record[0],
        index=record[1],
        valid=valid,
        key=key,
    )


def set_response_confirms_target(inner: bytes) -> bool:
    """Require an exact key/value echo; ambiguous replies never count as success."""

    try:
        record = response_record(inner, SET_FF_VALUE)
    except ProbeTransportError:
        return False
    return record == TARGET_SET_PAYLOAD


def validate_plan(
    *,
    action: str,
    peripheral_id: str,
    output_dir: Path,
    baseline_seconds: float,
    post_seconds: float,
    response_timeout_seconds: float,
    unknown_state_ack: str | None = None,
    persistent_write_ack: str | None = None,
    positive_walk_label: str | None = None,
    arm_motion_control_label: str | None = None,
    quiet_phase_seconds: float = DEFAULT_QUIET_PHASE_SECONDS,
    positive_walk_seconds: float = DEFAULT_ACTIVITY_PHASE_SECONDS,
    arm_motion_control_seconds: float = DEFAULT_ACTIVITY_PHASE_SECONDS,
    banked_discovery: bool = False,
    history_observation_seconds: float = 30.0,
    history_byte_cap: int = 1_000_000,
    operator_cues: bool = False,
) -> ProbePlan:
    if action not in {"enumerate", "enable"}:
        raise ProbeRefusal(f"unsupported action: {action!r}")
    canonical_id = canonical_peripheral_id(peripheral_id)
    if action == "enable" and canonical_id != PINNED_PERIPHERAL_ID:
        raise ProbeRefusal(
            "persistent experiment is pinned to the exact CoreBluetooth UUID "
            f"{PINNED_PERIPHERAL_ID}"
        )
    if not all(
        math.isfinite(value)
        for value in (
            baseline_seconds,
            post_seconds,
            response_timeout_seconds,
            quiet_phase_seconds,
            positive_walk_seconds,
            arm_motion_control_seconds,
            history_observation_seconds,
        )
    ):
        raise ProbeRefusal("durations and timeouts must be finite")
    if baseline_seconds < 0 or post_seconds < 0:
        raise ProbeRefusal("observation durations cannot be negative")
    if (
        baseline_seconds > MAX_OBSERVATION_SECONDS
        or post_seconds > MAX_OBSERVATION_SECONDS
    ):
        raise ProbeRefusal(
            f"each observation duration must be at most "
            f"{MAX_OBSERVATION_SECONDS:.0f} seconds"
        )
    if response_timeout_seconds <= 0 or response_timeout_seconds > 30:
        raise ProbeRefusal("response timeout must be in (0, 30] seconds")

    unknown_acknowledged = unknown_state_ack == UNKNOWN_STATE_ACK
    write_authorized = persistent_write_ack == PERSISTENT_WRITE_ACK
    if action == "enable":
        if not operator_cues:
            raise ProbeRefusal(
                "persistent experiment requires fixed operator cues"
            )
        if not banked_discovery:
            raise ProbeRefusal(
                "persistent action requires the banked-discovery safety firewall"
            )
        if not unknown_acknowledged:
            raise ProbeRefusal(
                "persistent action requires the exact unknown-prior-state "
                "acknowledgement"
            )
        if not write_authorized:
            raise ProbeRefusal(
                "persistent action requires the exact write authorization"
            )
        if baseline_seconds != 0 or post_seconds != 0:
            raise ProbeRefusal(
                "persistent action uses only the fixed short labelled phase "
                "sequence; "
                "baseline/post durations must be zero"
            )
        positive_walk_label = _validated_activity_label(
            positive_walk_label, "positive-walk"
        )
        arm_motion_control_label = _validated_activity_label(
            arm_motion_control_label, "arm-motion-control"
        )
        if positive_walk_label == arm_motion_control_label:
            raise ProbeRefusal(
                "positive-walk and arm-motion-control labels must be distinct"
            )
        if not MIN_QUIET_PHASE_SECONDS <= quiet_phase_seconds <= MAX_QUIET_PHASE_SECONDS:
            raise ProbeRefusal("quiet phases must be between 2 and 5 seconds")
        for name, duration in (
            ("positive walk", positive_walk_seconds),
            ("arm-motion control", arm_motion_control_seconds),
        ):
            if not MIN_ACTIVITY_PHASE_SECONDS <= duration <= MAX_ACTIVITY_PHASE_SECONDS:
                raise ProbeRefusal(
                    f"{name} phase must be between 10 and 12 seconds"
                )
    elif positive_walk_label is not None or arm_motion_control_label is not None:
        raise ProbeRefusal(
            "activity comparison labels belong only to the persistent experiment"
        )
    if operator_cues and action != "enable":
        raise ProbeRefusal(
            "operator cues are available only during the persistent experiment"
        )

    banked_observation: BankedDiscoveryObservation | None = None
    if banked_discovery:
        if action != "enable":
            raise ProbeRefusal(
                "banked discovery is available only during the persistent action"
            )
        if (
            history_observation_seconds <= 0
            or history_observation_seconds > MAX_HISTORY_OBSERVATION_SECONDS
        ):
            raise ProbeRefusal(
                "history observation time must be in (0, 75] seconds"
            )
        if (
            history_byte_cap <= 0
            or history_byte_cap > MAX_HISTORY_OBSERVATION_BYTES
        ):
            raise ProbeRefusal(
                "history byte cap must be in (0, 8388608]"
            )
        banked_observation = BankedDiscoveryObservation(
            timeout_seconds=history_observation_seconds,
            byte_cap=history_byte_cap,
        )

    return ProbePlan(
        action=action,
        peripheral_id=canonical_id,
        output_dir=output_dir.expanduser().resolve(),
        baseline_seconds=baseline_seconds,
        post_seconds=post_seconds,
        response_timeout_seconds=response_timeout_seconds,
        unknown_state_acknowledged=unknown_acknowledged,
        persistent_write_authorized=write_authorized,
        positive_walk_label=positive_walk_label,
        arm_motion_control_label=arm_motion_control_label,
        quiet_phase_seconds=quiet_phase_seconds,
        positive_walk_seconds=positive_walk_seconds,
        arm_motion_control_seconds=arm_motion_control_seconds,
        banked_discovery=banked_observation,
        operator_cues_enabled=operator_cues,
    )


def _validated_activity_label(value: str | None, kind: str) -> str:
    if value is None:
        raise ProbeRefusal(
            f"persistent action requires an explicit {kind} phase label"
        )
    normalized = value.strip()
    if not normalized:
        raise ProbeRefusal(f"{kind} phase label cannot be empty")
    if len(normalized.encode("utf-8")) > MAX_ACTIVITY_LABEL_BYTES:
        raise ProbeRefusal(
            f"{kind} phase label exceeds {MAX_ACTIVITY_LABEL_BYTES} UTF-8 bytes"
        )
    return normalized


class FrameReassembler:
    """Per-characteristic WHOOP frame reassembly."""

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.discarded_bytes = 0

    def feed(self, chunk: bytes) -> list[bytes]:
        self.buffer.extend(chunk)
        frames: list[bytes] = []
        while True:
            try:
                marker = self.buffer.index(0xAA)
            except ValueError:
                self.discarded_bytes += len(self.buffer)
                self.buffer.clear()
                break
            if marker:
                self.discarded_bytes += marker
                del self.buffer[:marker]
            if len(self.buffer) < 4:
                break
            if crc8(bytes(self.buffer[1:3])) != self.buffer[3]:
                self.discarded_bytes += 1
                del self.buffer[0]
                continue
            length = int.from_bytes(self.buffer[1:3], "little")
            total = length + 4
            if length < 7 or total > MAX_FRAME_BYTES:
                self.discarded_bytes += 1
                del self.buffer[0]
                continue
            if len(self.buffer) < total:
                break
            candidate = bytes(self.buffer[:total])
            del self.buffer[:total]
            try:
                frame_inner(candidate)
            except ProbeTransportError:
                self.discarded_bytes += len(candidate)
                continue
            frames.append(candidate)
        return frames


class CorpusRecorder:
    """Append-only, lossless notification/frame corpus plus histograms."""

    def __init__(self, path: Path, now: Callable[[], float] = time.time) -> None:
        self.path = path
        self.now = now
        self.phase = "setup"
        self.reassemblers = {
            characteristic: FrameReassembler()
            for characteristic in NOTIFICATION_CHARACTERISTICS
        }
        self.histogram: Counter[
            tuple[str, str, int, int | None, int | None, int]
        ] = Counter()
        self.notification_histogram: Counter[tuple[str, str, int]] = Counter()
        self.notification_bytes: Counter[tuple[str, str]] = Counter()
        self.handle = path.open("x", encoding="utf-8")

    def close(self) -> None:
        if not self.handle.closed:
            self.handle.flush()
            os.fsync(self.handle.fileno())
            self.handle.close()

    def set_phase(self, phase: str) -> None:
        self.checkpoint()
        self.phase = phase

    def checkpoint(self) -> None:
        self.handle.flush()
        os.fsync(self.handle.fileno())

    def record_notification(
        self, characteristic: str, data: bytes
    ) -> list[bytes]:
        normalized = characteristic.lower()
        reassembler = self.reassemblers.get(normalized)
        if reassembler is None:
            raise ProbeTransportError(
                f"notification arrived on unallowlisted characteristic "
                f"{characteristic}"
            )
        captured_at = self.now()
        self.notification_histogram[(self.phase, normalized, len(data))] += 1
        self.notification_bytes[(self.phase, normalized)] += len(data)
        self.handle.write(
            json.dumps(
                {
                    "schema": 2,
                    "kind": "notification",
                    "capturedAtUnix": captured_at,
                    "phase": self.phase,
                    "characteristic": normalized,
                    "notificationLength": len(data),
                    "notificationHex": data.hex(),
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        )
        frames = reassembler.feed(data)
        for frame in frames:
            inner = frame_inner(frame)
            packet_type = inner[0]
            second_byte = inner[1] if len(inner) >= 2 else None
            record_version = (
                inner[1]
                if packet_type == HISTORICAL_PACKET_TYPE and len(inner) >= 2
                else None
            )
            record_type = (
                inner[1]
                if packet_type == REALTIME_RAW_PACKET_TYPE and len(inner) >= 2
                else None
            )
            self.histogram[
                (
                    self.phase,
                    normalized,
                    packet_type,
                    record_version,
                    record_type,
                    len(inner),
                )
            ] += 1
            row: dict[str, Any] = {
                "schema": 2,
                "kind": "frame",
                "capturedAtUnix": captured_at,
                "phase": self.phase,
                "characteristic": normalized,
                "notificationLength": len(data),
                "frameLength": len(frame),
                "innerLength": len(inner),
                "packetType": packet_type,
                "packetTypeHex": f"{packet_type:02x}",
                "secondByte": second_byte,
                "recordVersion": record_version,
                "recordType": record_type,
                "innerPrefixHex": inner[:32].hex(),
                "frameHex": frame.hex(),
                "innerHex": inner.hex(),
                "crcValid": True,
            }
            self.handle.write(
                json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
            )
        self.handle.flush()
        return frames

    def summary(self) -> dict[str, Any]:
        rows = []
        for (
            phase,
            characteristic,
            packet_type,
            record_version,
            record_type,
            inner_length,
        ), count in sorted(
            self.histogram.items(),
            key=lambda item: (
                item[0][0],
                item[0][1],
                item[0][2],
                item[0][3] if item[0][3] is not None else -1,
                item[0][4] if item[0][4] is not None else -1,
                item[0][5],
            ),
        ):
            rows.append(
                {
                    "phase": phase,
                    "characteristic": characteristic,
                    "packetType": packet_type,
                    "packetTypeHex": f"{packet_type:02x}",
                    "recordVersion": record_version,
                    "recordType": record_type,
                    "innerLength": inner_length,
                    "count": count,
                }
            )
        notification_rows = [
            {
                "phase": phase,
                "characteristic": characteristic,
                "notificationLength": length,
                "count": count,
            }
            for (phase, characteristic, length), count in sorted(
                self.notification_histogram.items()
            )
        ]
        return {
            "schema": 2,
            "rows": rows,
            "notifications": notification_rows,
            "notificationBytes": [
                {
                    "phase": phase,
                    "characteristic": characteristic,
                    "bytes": count,
                }
                for (phase, characteristic), count in sorted(
                    self.notification_bytes.items()
                )
            ],
            "discardedBytes": {
                characteristic: reassembler.discarded_bytes
                for characteristic, reassembler in self.reassemblers.items()
            },
        }


class CommandChannel:
    """One-shot WHOOP command/response channel with no automatic retries."""

    def __init__(
        self,
        client: Any,
        recorder: CorpusRecorder,
        *,
        persistent_write_authorized: bool = False,
        empty_history_preflight_required: bool = False,
        persistent_attempt_guard: Callable[[], None] | None = None,
    ) -> None:
        self.client = client
        self.recorder = recorder
        self.acknowledgements_authorized = persistent_write_authorized
        self.empty_history_preflight_required = (
            empty_history_preflight_required
        )
        self.persistent_write_authorized = (
            persistent_write_authorized
            and not empty_history_preflight_required
        )
        self.persistent_attempt_guard = persistent_attempt_guard
        self.queue: asyncio.Queue[bytes] = asyncio.Queue()
        self.sequence = 0
        self.set_write_attempted = False
        self.history_trace: list[int] = []

    def authorize_after_empty_history_preflight(
        self, cursor: DataRangeCursor
    ) -> None:
        """Unlock 0x78 only after the banked path proves W==U."""

        if not self.empty_history_preflight_required:
            raise ProbeRefusal("empty-history preflight was not required")
        if not self.acknowledgements_authorized:
            raise ProbeRefusal(
                "persistent 0x78 write lacks both exact acknowledgements"
            )
        if self.history_trace != [GET_DATA_RANGE]:
            raise ProbeRefusal(
                "empty-history authorization requires one completed 0x22 preflight"
            )
        require_empty_history_preflight(cursor)
        self.persistent_write_authorized = True

    def receive_frames(self, frames: list[bytes]) -> None:
        for frame in frames:
            inner = frame_inner(frame)
            if inner and inner[0] == COMMAND_RESPONSE_PACKET_TYPE:
                self.queue.put_nowait(frame)

    def _drain_responses(self) -> None:
        while not self.queue.empty():
            self.queue.get_nowait()

    async def call(
        self, opcode: int, payload: bytes, timeout_seconds: float
    ) -> bytes:
        validate_command(opcode, payload)
        if opcode == SET_FF_VALUE:
            if not self.persistent_write_authorized:
                raise ProbeRefusal(
                    "persistent 0x78 write lacks both exact acknowledgements"
                )
            if self.set_write_attempted:
                raise ProbeRefusal("persistent 0x78 write may be attempted only once")
            if self.persistent_attempt_guard is None:
                raise ProbeRefusal(
                    "persistent 0x78 write lacks a durable at-most-once guard"
                )
            self.persistent_attempt_guard()
            self.set_write_attempted = True
        self._drain_responses()
        self.sequence = (self.sequence + 1) & 0xFF
        request_sequence = self.sequence
        frame = command_frame(opcode, payload, request_sequence)
        try:
            await asyncio.wait_for(
                self.client.write_gatt_char(
                    COMMAND_TO_STRAP, frame, response=True
                ),
                timeout=timeout_seconds,
            )
        except asyncio.TimeoutError as error:
            raise ProbeTransportError(
                f"timeout writing 0x{opcode:02x}; the command will not be retried"
            ) from error
        deadline = asyncio.get_running_loop().time() + timeout_seconds
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise ProbeTransportError(
                    f"timeout waiting for response to 0x{opcode:02x}; "
                    "the command will not be retried"
                )
            try:
                response_frame = await asyncio.wait_for(
                    self.queue.get(), timeout=remaining
                )
            except asyncio.TimeoutError as error:
                raise ProbeTransportError(
                    f"timeout waiting for response to 0x{opcode:02x}; "
                    "the command will not be retried"
                ) from error
            inner = frame_inner(response_frame)
            if (
                len(inner) >= 4
                and inner[2] == opcode
                and inner[3] == request_sequence
            ):
                return inner

    def _authorize_history_step(self, opcode: int, payload: bytes) -> None:
        expected_trace = (
            GET_DATA_RANGE,
            SEND_HISTORICAL,
            ABORT_HISTORICAL,
            GET_DATA_RANGE,
        )
        if len(self.history_trace) >= len(expected_trace):
            raise ProbeRefusal("first-chunk history trace may run only once")
        expected = expected_trace[len(self.history_trace)]
        if opcode != expected:
            raise ProbeRefusal(
                f"first-chunk history trace expected 0x{expected:02x}, "
                f"not 0x{opcode:02x}"
            )
        validate_history_command(opcode, payload)

    async def _write_history_frame(
        self,
        opcode: int,
        payload: bytes,
        *,
        timeout_seconds: float,
    ) -> int:
        if timeout_seconds <= 0 or timeout_seconds > 30:
            raise ProbeRefusal("history write timeout must be in (0, 30] seconds")
        self._authorize_history_step(opcode, payload)
        self.sequence = (self.sequence + 1) & 0xFF
        request_sequence = self.sequence
        frame = history_command_frame(opcode, payload, request_sequence)
        self.history_trace.append(opcode)
        try:
            await asyncio.wait_for(
                self.client.write_gatt_char(
                    COMMAND_TO_STRAP, frame, response=True
                ),
                timeout=timeout_seconds,
            )
        except asyncio.TimeoutError as error:
            raise ProbeTransportError(
                f"timeout writing history opcode 0x{opcode:02x}; "
                "the command will not be retried"
            ) from error
        return request_sequence

    async def call_data_range(self, *, timeout_seconds: float) -> DataRangeCursor:
        """Issue the next allowlisted 22/00 and parse its full-frame W/U/T."""

        self._drain_responses()
        request_sequence = await self._write_history_frame(
            GET_DATA_RANGE,
            ZERO_PAYLOAD,
            timeout_seconds=timeout_seconds,
        )
        deadline = asyncio.get_running_loop().time() + timeout_seconds
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise ProbeTransportError(
                    "timeout waiting for GET_DATA_RANGE; no command is retried"
                )
            try:
                response_frame = await asyncio.wait_for(
                    self.queue.get(), timeout=remaining
                )
            except asyncio.TimeoutError as error:
                raise ProbeTransportError(
                    "timeout waiting for GET_DATA_RANGE; no command is retried"
                ) from error
            inner = frame_inner(response_frame)
            if (
                len(inner) >= 4
                and inner[2] == GET_DATA_RANGE
                and inner[3] == request_sequence
            ):
                return parse_data_range_cursor_frame(response_frame)

    async def write_history_command(
        self,
        opcode: int,
        payload: bytes,
        *,
        timeout_seconds: float = 5.0,
    ) -> None:
        """Write the next 16/00 or 14/00 step without waiting for a command ACK."""

        if opcode not in {SEND_HISTORICAL, ABORT_HISTORICAL}:
            raise ProbeRefusal(
                "write-only history path admits only SEND_HISTORICAL or ABORT"
            )
        await self._write_history_frame(
            opcode, payload, timeout_seconds=timeout_seconds
        )


class HistoryCaptureBudget:
    """Strict admission budget for the optional history observation."""

    def __init__(self, *, timeout_seconds: float, byte_cap: int) -> None:
        if (
            not math.isfinite(timeout_seconds)
            or timeout_seconds <= 0
            or timeout_seconds > MAX_HISTORY_OBSERVATION_SECONDS
        ):
            raise ProbeRefusal("invalid history observation timeout")
        if byte_cap <= 0 or byte_cap > MAX_HISTORY_OBSERVATION_BYTES:
            raise ProbeRefusal("invalid history observation byte cap")
        self.timeout_seconds = timeout_seconds
        self.byte_cap = byte_cap
        self.accepted_bytes = 0
        self.rejected_notifications = 0
        self.rejected_bytes = 0
        self.active = False
        self.data_admission_closed = False
        self.deadline_monotonic: float | None = None
        self.stop_event = asyncio.Event()
        self.stop_reason: str | None = None
        self.historical_rows = 0
        self.historical_timestamps: list[int] = []
        self.first_history_end_hex: str | None = None
        self.history_complete_before_end = False

    def begin(self) -> None:
        if self.active:
            raise ProbeRefusal("history capture budget is already active")
        self.active = True
        self.deadline_monotonic = (
            asyncio.get_running_loop().time() + self.timeout_seconds
        )

    def finish(self) -> None:
        self.active = False

    def admits(self, byte_count: int) -> bool:
        """Admit a complete notification or reject it before crossing the cap."""

        if not self.active:
            return True
        if byte_count < 0:
            raise ProbeRefusal("notification byte count cannot be negative")
        if (
            self.deadline_monotonic is not None
            and asyncio.get_running_loop().time()
                >= self.deadline_monotonic
        ):
            self.stop_reason = "time_cap"
            self.data_admission_closed = True
            self.stop_event.set()
        if self.data_admission_closed:
            self.rejected_notifications += 1
            self.rejected_bytes += byte_count
            return False
        if self.accepted_bytes + byte_count > self.byte_cap:
            self.rejected_notifications += 1
            self.rejected_bytes += byte_count
            self.stop_reason = "byte_cap_before_notification"
            self.data_admission_closed = True
            self.stop_event.set()
            return False
        self.accepted_bytes += byte_count
        if self.accepted_bytes == self.byte_cap:
            self.stop_reason = "byte_cap_exact"
            self.data_admission_closed = True
            self.stop_event.set()
        return True

    def observe_frames(self, frames: list[bytes]) -> None:
        """Classify only rows up to and including the first HISTORY_END."""

        if not self.active or self.first_history_end_hex is not None:
            return
        for frame in frames:
            inner = frame_inner(frame)
            if not inner:
                continue
            if inner[0] == HISTORICAL_PACKET_TYPE:
                self.historical_rows += 1
                if len(inner) >= 11:
                    self.historical_timestamps.append(
                        int.from_bytes(inner[7:11], "little")
                    )
                continue
            if len(inner) >= 3 and inner[0] == 0x31:
                if inner[2] == 0x02 and len(inner) >= 21:
                    self.first_history_end_hex = inner.hex()
                    self.stop_reason = "first_history_end"
                    self.data_admission_closed = True
                    self.stop_event.set()
                    return
                if inner[2] == 0x03:
                    self.history_complete_before_end = True
                    self.stop_reason = "history_complete_before_history_end"
                    self.data_admission_closed = True
                    self.stop_event.set()
                    return

    async def wait(self) -> str:
        if self.deadline_monotonic is None:
            raise ProbeRefusal("history capture budget was not started")
        remaining = (
            self.deadline_monotonic - asyncio.get_running_loop().time()
        )
        if remaining <= 0:
            self.stop_reason = "time_cap"
            self.data_admission_closed = True
            self.stop_event.set()
            return self.stop_reason
        try:
            await asyncio.wait_for(
                self.stop_event.wait(), timeout=remaining
            )
        except asyncio.TimeoutError:
            self.stop_reason = "time_cap"
            self.data_admission_closed = True
            self.stop_event.set()
        return self.stop_reason or "time_cap"

    def report(self) -> dict[str, Any]:
        return {
            "timeCapSeconds": self.timeout_seconds,
            "dataLaneByteCap": self.byte_cap,
            "acceptedBytes": self.accepted_bytes,
            "rejectedNotificationsAtCap": self.rejected_notifications,
            "rejectedBytesAtCap": self.rejected_bytes,
            "stopReason": self.stop_reason,
            "historicalRowsBeforeFirstEnd": self.historical_rows,
            "historicalTimestampsBeforeFirstEnd": self.historical_timestamps,
            "firstHistoryEndObserved": self.first_history_end_hex is not None,
            "firstHistoryEndInnerHex": self.first_history_end_hex,
            "historyCompleteBeforeEnd": self.history_complete_before_end,
        }


async def observe_first_fifo_chunk(
    channel: CommandChannel,
    recorder: CorpusRecorder,
    observation: BankedDiscoveryObservation,
    budget: HistoryCaptureBudget,
    preflight: DataRangeCursor,
    labelled_phases: list[dict[str, Any]],
    *,
    response_timeout_seconds: float,
    post_abort_settle_seconds: float = POST_ABORT_SETTLE_SECONDS,
) -> dict[str, Any]:
    """Capture one FIFO page without ACK, then prove the read cursor did not move."""

    if preflight.write_cursor != preflight.read_cursor:
        raise ProbeRefusal(
            "preflight history backlog is non-empty; persistent write was forbidden"
        )
    if (
        budget.timeout_seconds != observation.timeout_seconds
        or budget.byte_cap != observation.byte_cap
    ):
        raise ProbeRefusal(
            "history budget does not match the validated observation plan"
        )
    if (
        not math.isfinite(post_abort_settle_seconds)
        or not 0
            <= post_abort_settle_seconds
            <= POST_RANGE_RESPONSE_SETTLE_SECONDS
    ):
        raise ProbeRefusal("post-abort settle exceeds its fixed bound")

    recorder.set_phase("history_first_fifo_chunk")
    budget.begin()
    serve_attempted = False
    try:
        try:
            serve_attempted = True
            await channel.write_history_command(
                SEND_HISTORICAL,
                ZERO_PAYLOAD,
                timeout_seconds=response_timeout_seconds,
            )
            stop_reason = await budget.wait()
        finally:
            if serve_attempted:
                recorder.set_phase("history_first_fifo_abort")
                await channel.write_history_command(
                    ABORT_HISTORICAL,
                    ZERO_PAYLOAD,
                    timeout_seconds=response_timeout_seconds,
                )
        await asyncio.sleep(post_abort_settle_seconds)
        recorder.set_phase("history_first_fifo_postflight")
        postflight = await channel.call_data_range(
            timeout_seconds=response_timeout_seconds
        )
    finally:
        budget.finish()
    read_cursor_unchanged = postflight.read_cursor == preflight.read_cursor
    capacity_unchanged = postflight.capacity == preflight.capacity
    device_clock_nonregressing = postflight.device_unix >= preflight.device_unix
    cursor_space_unchanged = postflight_preserves_cursor_space(
        preflight, postflight
    )
    timestamps = budget.historical_timestamps
    phase_presence: dict[str, int] = {}
    for phase in labelled_phases:
        start_unix = int(phase["startedAtUnix"])
        end_unix = int(phase["endedAtUnix"]) + 1
        phase_presence[phase["phase"]] = sum(
            start_unix <= timestamp <= end_unix for timestamp in timestamps
        )
    labelled_rows_present = all(
        phase_presence.get(name, 0) > 0 for name in LABELLED_ACTIVITY_PHASES
    )
    if not budget.first_history_end_hex:
        verdict = "indeterminate_no_first_history_end"
    elif not cursor_space_unchanged:
        verdict = "failed_postflight_cursor_space_changed_without_ack"
    elif not labelled_rows_present:
        verdict = "indeterminate_labelled_rows_not_in_first_chunk"
    else:
        verdict = "candidate_first_chunk_rows_observed_requires_signal_decoding"
    return {
        "firstChunkOnly": True,
        "commandTrace": [f"0x{opcode:02x}" for opcode in channel.history_trace],
        "historyACKSent": False,
        "historyTrimSent": False,
        "stopReason": stop_reason,
        "budget": budget.report(),
        "preflight": _cursor_dict(preflight),
        "postflight": _cursor_dict(postflight),
        "readCursorUnchanged": read_cursor_unchanged,
        "capacityUnchanged": capacity_unchanged,
        "deviceClockNonregressing": device_clock_nonregressing,
        "cursorSpaceUnchanged": cursor_space_unchanged,
        "labelledRowsByPhase": phase_presence,
        "verdict": verdict,
        "featureEffectClaimed": False,
    }


def _cursor_dict(cursor: DataRangeCursor) -> dict[str, int]:
    return {
        "writeCursorW": cursor.write_cursor,
        "readCursorU": cursor.read_cursor,
        "capacity": cursor.capacity,
        "deviceUnix": cursor.device_unix,
        "pendingIsZero": cursor.write_cursor == cursor.read_cursor,
    }


def postflight_preserves_cursor_space(
    preflight: DataRangeCursor,
    postflight: DataRangeCursor,
) -> bool:
    """Require the unacknowledged observation to leave cursor authority intact."""

    return (
        postflight.read_cursor == preflight.read_cursor
        and postflight.capacity == preflight.capacity
        and postflight.device_unix >= preflight.device_unix
    )


def require_empty_history_preflight(cursor: DataRangeCursor) -> None:
    """Refuse the experiment before 0x78 unless the FIFO is empty."""

    if cursor.write_cursor != cursor.read_cursor:
        raise ProbeRefusal(
            "history preflight W != U; refusing persistent write because "
            "the first FIFO chunk is pre-existing"
        )


async def enumerate_feature_keys(
    channel: CommandChannel, timeout_seconds: float
) -> tuple[FeatureFlagStart, list[FeatureFlagEntry]]:
    start_inner = await channel.call(
        START_FF_KEY_EXCHANGE,
        ENUMERATION_PAYLOAD,
        timeout_seconds,
    )
    start = decode_start_response(start_inner)
    entries: list[FeatureFlagEntry] = []
    seen_indices: set[int] = set()
    for _ in range(start.count):
        next_inner = await channel.call(
            SEND_NEXT_FF,
            ENUMERATION_PAYLOAD,
            timeout_seconds,
        )
        entry = decode_next_response(next_inner)
        if not entry.valid or entry.index == 0xFF:
            raise ProbeTransportError(
                "feature-key enumeration ended before the announced count"
            )
        if entry.key is None:
            raise ProbeTransportError(
                "feature-key enumeration returned an undecodable key"
            )
        if entry.index in seen_indices:
            raise ProbeTransportError(
                f"feature-key cursor repeated index {entry.index}"
            )
        seen_indices.add(entry.index)
        entries.append(entry)
    return start, entries


def require_pinned_feature_enumeration(
    *,
    peripheral_id: str,
    start: FeatureFlagStart,
    entries: list[FeatureFlagEntry],
) -> tuple[str, ...]:
    """Require the same exact flag snapshot observed by the pinned read-only run."""

    if canonical_peripheral_id(peripheral_id) != PINNED_PERIPHERAL_ID:
        raise ProbeRefusal(
            "same-run feature enumeration came from an unpinned peripheral"
        )
    if start.revision != PINNED_ENUMERATION_REVISION:
        raise ProbeRefusal(
            "same-run feature enumeration revision differs from pinned evidence"
        )
    if start.count != len(PINNED_ENUMERATION_KEYS):
        raise ProbeRefusal(
            "same-run feature enumeration count differs from pinned evidence"
        )
    if len(entries) != start.count:
        raise ProbeRefusal(
            "same-run feature enumeration did not return the announced count"
        )

    keys: list[str] = []
    seen_keys: set[str] = set()
    for expected_index, (expected_key, entry) in enumerate(
        zip(PINNED_ENUMERATION_KEYS, entries, strict=True)
    ):
        if (
            not entry.valid
            or entry.revision != PINNED_ENUMERATION_REVISION
            or entry.index != expected_index
            or entry.key != expected_key
        ):
            raise ProbeRefusal(
                "same-run feature enumeration order/index/revision differs "
                "from pinned evidence"
            )
        if entry.key in seen_keys:
            raise ProbeRefusal(
                "same-run feature enumeration contains a duplicate key"
            )
        seen_keys.add(entry.key)
        keys.append(entry.key)

    if keys.count(TARGET_FEATURE_KEY) != 1:
        raise ProbeRefusal(
            "same-run feature enumeration must contain the exact target once"
        )
    if tuple(keys) != PINNED_ENUMERATION_KEYS:
        raise ProbeRefusal(
            "same-run feature enumeration keys differ from pinned evidence"
        )
    return tuple(keys)


async def observe_short_activity_sequence(
    recorder: CorpusRecorder,
    *,
    sequence_prefix: str = "post_enable",
    quiet_seconds: float,
    positive_walk_seconds: float,
    arm_motion_control_seconds: float,
    positive_walk_label: str,
    arm_motion_control_label: str,
    operator_cue: OperatorCue | None = None,
) -> list[dict[str, Any]]:
    """Run the bounded quiet→walk→quiet→arm-control→quiet sequence."""

    if sequence_prefix not in ACTIVITY_SEQUENCE_PREFIXES:
        raise ProbeRefusal("activity sequence prefix is not allowlisted")
    schedule = (
        ("quiet_before_walk", "quiet_before_walk", quiet_seconds),
        ("positive_walk", positive_walk_label, positive_walk_seconds),
        ("quiet_between", "quiet_between", quiet_seconds),
        (
            "arm_motion_control",
            arm_motion_control_label,
            arm_motion_control_seconds,
        ),
        ("quiet_after_control", "quiet_after_control", quiet_seconds),
    )
    if operator_cue is not None:
        await deliver_operator_cue(
            operator_cue,
            OPERATOR_BOUNDARY_CUES[sequence_prefix],
        )
    result: list[dict[str, Any]] = []
    for activity, operator_label, duration in schedule:
        if operator_cue is not None:
            await deliver_operator_cue(
                operator_cue,
                OPERATOR_PHASE_CUES[activity],
            )
        phase = f"{sequence_prefix}_{activity}"
        recorder.set_phase(phase)
        print(
            f"BEGIN {phase}: {operator_label} for {duration:.1f} seconds",
            file=sys.stderr,
            flush=True,
        )
        started_at_unix = time.time()
        started_at = datetime.now(timezone.utc).isoformat()
        await asyncio.sleep(duration)
        ended_at_unix = time.time()
        result.append(
            {
                "phase": phase,
                "sequence": sequence_prefix,
                "activity": activity,
                "operatorLabel": operator_label,
                "operatorLabelTruth": (
                    "planned_or_externally_reported_not_verified_by_harness"
                ),
                "activityVerifiedByHarness": False,
                "durationSeconds": duration,
                "startedAt": started_at,
                "startedAtUnix": started_at_unix,
                "endedAt": datetime.now(timezone.utc).isoformat(),
                "endedAtUnix": ended_at_unix,
            }
        )
    return result


async def observe_matched_enable_trial(
    recorder: CorpusRecorder,
    *,
    persistent_set_action: PersistentSetAction,
    quiet_seconds: float,
    positive_walk_seconds: float,
    arm_motion_control_seconds: float,
    positive_walk_label: str,
    arm_motion_control_label: str,
    operator_cue: OperatorCue | None = None,
) -> dict[str, Any]:
    """Capture matched pre/post sequences around exactly one set action."""

    pre_enable = await observe_short_activity_sequence(
        recorder,
        sequence_prefix="pre_enable",
        quiet_seconds=quiet_seconds,
        positive_walk_seconds=positive_walk_seconds,
        arm_motion_control_seconds=arm_motion_control_seconds,
        positive_walk_label=positive_walk_label,
        arm_motion_control_label=arm_motion_control_label,
        operator_cue=operator_cue,
    )
    persistent_write = await persistent_set_action()
    post_enable = await observe_short_activity_sequence(
        recorder,
        sequence_prefix="post_enable",
        quiet_seconds=quiet_seconds,
        positive_walk_seconds=positive_walk_seconds,
        arm_motion_control_seconds=arm_motion_control_seconds,
        positive_walk_label=positive_walk_label,
        arm_motion_control_label=arm_motion_control_label,
        operator_cue=operator_cue,
    )
    return {
        "preEnable": pre_enable,
        "persistentWrite": persistent_write,
        "postEnable": post_enable,
        "combinedPhases": [*pre_enable, *post_enable],
    }


def _compare_phase_pair(
    summary: dict[str, Any],
    walk_phase: str,
    control_phase: str,
) -> dict[str, Any]:
    signatures: dict[str, Counter[tuple[Any, ...]]] = {
        walk_phase: Counter(),
        control_phase: Counter(),
    }
    for row in summary.get("rows", []):
        phase = str(row.get("phase", ""))
        if phase not in signatures:
            continue
        signature = (
            row.get("characteristic"),
            row.get("packetType"),
            row.get("recordVersion"),
            row.get("recordType"),
            row.get("innerLength"),
        )
        signatures[phase][signature] += int(row.get("count", 0))

    walk_total = sum(signatures[walk_phase].values())
    control_total = sum(signatures[control_phase].values())
    walk_only_signatures = sorted(
        set(signatures[walk_phase]) - set(signatures[control_phase]),
        key=repr,
    )
    count_deltas = []
    for signature in sorted(
        set(signatures[walk_phase]) | set(signatures[control_phase]),
        key=repr,
    ):
        walk_count = signatures[walk_phase][signature]
        control_count = signatures[control_phase][signature]
        if walk_count != control_count:
            count_deltas.append(
                {
                    "signature": list(signature),
                    "walkCount": walk_count,
                    "armControlCount": control_count,
                    "delta": walk_count - control_count,
                }
            )

    if walk_total == 0 or control_total == 0:
        verdict = "inconclusive_missing_packets"
    elif not walk_only_signatures and not count_deltas:
        verdict = "inconclusive_no_observed_difference"
    else:
        verdict = "candidate_difference_observed_requires_decoding"
    return {
        "verdict": verdict,
        "featureEffectClaimed": False,
        "positiveWalkFrameCount": walk_total,
        "armMotionControlFrameCount": control_total,
        "walkOnlySignatures": [
            list(signature) for signature in walk_only_signatures
        ],
        "countDeltas": count_deltas,
        "silenceIsSuccess": False,
    }


def compare_labelled_activity(summary: dict[str, Any]) -> dict[str, Any]:
    """Compare walk/control packet signatures; silence is never success."""

    pre_enable = _compare_phase_pair(
        summary,
        "pre_enable_positive_walk",
        "pre_enable_arm_motion_control",
    )
    post_enable = _compare_phase_pair(
        summary,
        "post_enable_positive_walk",
        "post_enable_arm_motion_control",
    )
    return {
        **post_enable,
        "preEnable": pre_enable,
        "postEnable": post_enable,
        "comparisonScope": "matched_pre_enable_and_post_enable_sequences",
    }


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    with temporary.open("rb") as handle:
        os.fsync(handle.fileno())
    temporary.replace(path)


def _manifest(plan: ProbePlan) -> dict[str, Any]:
    manifest: dict[str, Any] = {
        "schema": 3,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "action": plan.action,
        "peripheralID": plan.peripheral_id,
        "experimentHypothesis": (
            "setting enable_false_step_detection to ASCII 1 may alter "
            "false-step filtering; neither value semantics nor effect is claimed"
        ),
        "effectClaimed": False,
        "pinnedPhysicalEnumeration": {
            "requiredForPersistentAction": True,
            "path": str(PINNED_ENUMERATION_EVIDENCE_PATH),
            "sha256": PINNED_ENUMERATION_EVIDENCE_SHA256,
            "peripheralID": PINNED_PERIPHERAL_ID,
            "revision": PINNED_ENUMERATION_REVISION,
            "announcedCount": len(PINNED_ENUMERATION_KEYS),
            "orderedKeys": list(PINNED_ENUMERATION_KEYS),
            "artifactVerified": False,
            "sameRunSnapshotVerified": False,
        },
        "baselineSeconds": plan.baseline_seconds,
        "postSeconds": plan.post_seconds,
        "responseTimeoutSeconds": plan.response_timeout_seconds,
        "allowedOpcodes": [
            f"0x{opcode:02x}"
            for opcode in (
                (START_FF_KEY_EXCHANGE, SEND_NEXT_FF)
                if plan.action == "enumerate"
                else (
                    START_FF_KEY_EXCHANGE,
                    SEND_NEXT_FF,
                    SET_FF_VALUE,
                )
            )
        ],
        "allowedPersistentKey": TARGET_FEATURE_KEY,
        "allowedPersistentValue": TARGET_FEATURE_VALUE,
        "unknownPriorState": True,
        "priorStateReadable": False,
        "priorStateRestorable": False,
        "unknownStateAcknowledged": plan.unknown_state_acknowledged,
        "persistentWriteAuthorized": plan.persistent_write_authorized,
        "operatorCues": {
            "enabled": plan.operator_cues_enabled,
            "implementation": (
                MACOS_SAY_PATH if plan.operator_cues_enabled else None
            ),
            "fixedTextOnly": True,
            "userLabelsSpoken": False,
            "timeoutSeconds": OPERATOR_CUE_TIMEOUT_SECONDS,
        },
        "activityPhases": {
            "positiveWalkLabel": plan.positive_walk_label,
            "armMotionControlLabel": plan.arm_motion_control_label,
            "operatorLabelTruth": (
                "planned_or_externally_reported_not_verified_by_harness"
            ),
            "activityVerifiedByHarness": False,
            "order": [
                f"{prefix}_{activity}"
                for prefix in ACTIVITY_SEQUENCE_PREFIXES
                for activity in ACTIVITY_SEQUENCE_STAGES
            ],
            "sequenceOrder": list(ACTIVITY_SEQUENCE_PREFIXES),
            "boundaryCues": dict(OPERATOR_BOUNDARY_CUES),
            "quietSeconds": plan.quiet_phase_seconds,
            "positiveWalkSeconds": plan.positive_walk_seconds,
            "armMotionControlSeconds": plan.arm_motion_control_seconds,
        },
        "rollbackSemantics": {
            "implementedByHarness": False,
            "priorStateRestored": False,
            "priorStateRestorePossible": False,
            "onlyHonestFutureRollbackState": None,
            "explanation": (
                "The prior value and this key's value semantics are unknowable. "
                "Any later write would establish another value, not restore the "
                "prior state. This harness intentionally exposes no rollback."
            ),
        },
        "forbiddenOperations": [
            "clock",
            "reboot",
            "history ACK",
            "history trim",
            "history rewind",
            "history cursor mutation",
            "raw-mode toggle",
            "research-packet write",
            "any other feature key",
            "any other feature value",
        ],
        "status": "prepared",
    }
    if plan.banked_discovery is None:
        manifest["bankedDiscovery"] = {
            "enabled": False,
            "allowedOpcodes": [],
            "exactSelectorSupported": False,
        }
    else:
        observation = plan.banked_discovery
        manifest["bankedDiscovery"] = {
            "enabled": True,
            "allowedOpcodes": [
                f"0x{opcode:02x}"
                for opcode in (
                    GET_DATA_RANGE,
                    SEND_HISTORICAL,
                    ABORT_HISTORICAL,
                )
            ],
            "timeCapSeconds": observation.timeout_seconds,
            "dataLaneByteCap": observation.byte_cap,
            "servePayloadHex": "00",
            "firstFIFOChunkOnly": True,
            "exactSelectorSupported": False,
            "preflightRequiresPendingZero": True,
            "postflightRequiresReadCursorUnchanged": True,
            "postflightRequiresCapacityUnchanged": True,
            "postflightRequiresNonregressingDeviceClock": True,
            "historyACKReachable": False,
            "historyTrimReachable": False,
        }
    return manifest


async def run_probe(
    plan: ProbePlan,
    *,
    operator_cue: OperatorCue | None = None,
) -> dict[str, Any]:
    """Run the probe; offline tests stop at cue preflight before Bluetooth."""

    pinned_artifact_verified = False
    if plan.action == "enable":
        if plan.banked_discovery is None:
            raise ProbeRefusal(
                "persistent action requires the banked-discovery safety firewall"
            )
        if not plan.operator_cues_enabled:
            raise ProbeRefusal(
                "persistent experiment requires fixed operator cues"
            )
        if plan.peripheral_id != PINNED_PERIPHERAL_ID:
            raise ProbeRefusal(
                "persistent experiment peripheral differs from pinned evidence"
            )
        verify_pinned_enumeration_evidence()
        pinned_artifact_verified = True
    active_operator_cue: OperatorCue | None = None
    if plan.operator_cues_enabled:
        active_operator_cue = operator_cue or macos_say_operator_cue
        # This ready-check intentionally precedes the deferred Bluetooth import,
        # scanning, enumeration, and the durable one-shot 0x78 attempt.
        await preflight_operator_cue(active_operator_cue)

    # Deliberately deferred: importing this file remains Bluetooth-inert.
    try:
        from bleak import BleakClient, BleakScanner
    except ImportError as error:
        raise ProbeTransportError(
            "bleak is required only for an explicitly invoked hardware probe"
        ) from error

    plan.output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    manifest_path = plan.output_dir / f"false-step-flag-{stamp}-manifest.json"
    corpus_path = plan.output_dir / f"false-step-flag-{stamp}-corpus.jsonl"
    summary_path = plan.output_dir / f"false-step-flag-{stamp}-summary.json"
    if any(path.exists() for path in (manifest_path, corpus_path, summary_path)):
        raise ProbeRefusal("refusing to overwrite an existing probe artifact")

    manifest = _manifest(plan)
    manifest["pinnedPhysicalEnumeration"]["artifactVerified"] = (
        pinned_artifact_verified
    )
    manifest["corpusPath"] = str(corpus_path)
    manifest["summaryPath"] = str(summary_path)
    attempt_guard = (
        DurableSetAttemptGuard(
            DEFAULT_ATTEMPT_GUARD_DIRECTORY,
            plan.peripheral_id,
        )
        if plan.action == "enable"
        else None
    )
    if attempt_guard is not None:
        manifest["persistentAttemptGuard"] = {
            "path": str(attempt_guard.path),
            "exclusive": True,
            "crashDurable": True,
            "deletedByHarness": False,
        }
    _atomic_json(manifest_path, manifest)
    recorder = CorpusRecorder(corpus_path)
    channel: CommandChannel | None = None
    history_budget = (
        HistoryCaptureBudget(
            timeout_seconds=plan.banked_discovery.timeout_seconds,
            byte_cap=plan.banked_discovery.byte_cap,
        )
        if plan.banked_discovery is not None
        else None
    )

    try:
        device = await BleakScanner.find_device_by_address(
            plan.peripheral_id, timeout=20.0
        )
        if device is None:
            raise ProbeTransportError(
                f"exact peripheral {plan.peripheral_id} was not found"
            )
        discovered_id = canonical_peripheral_id(device.address)
        if discovered_id != plan.peripheral_id:
            raise ProbeRefusal(
                "scanner returned a peripheral whose UUID does not match the pin"
            )

        async with BleakClient(device) as client:
            connected_id = canonical_peripheral_id(client.address)
            if connected_id != plan.peripheral_id:
                raise ProbeRefusal(
                    "connected peripheral UUID does not match the pin"
                )
            channel = CommandChannel(
                client,
                recorder,
                persistent_write_authorized=plan.allows_persistent_write,
                empty_history_preflight_required=(
                    plan.banked_discovery is not None
                ),
                persistent_attempt_guard=(
                    attempt_guard.claim
                    if attempt_guard is not None
                    else None
                ),
            )

            def notification_handler(
                characteristic: str,
            ) -> Callable[[Any, bytearray], None]:
                normalized = characteristic.lower()

                def handle(_: Any, data: bytearray) -> None:
                    if (
                        history_budget is not None
                        and history_budget.active
                        and normalized == DATA_FROM_STRAP
                        and not history_budget.admits(len(data))
                    ):
                        return
                    frames = recorder.record_notification(
                        normalized, bytes(data)
                    )
                    if history_budget is not None and history_budget.active:
                        history_budget.observe_frames(frames)
                    if normalized == COMMAND_FROM_STRAP:
                        channel.receive_frames(frames)

                return handle

            for characteristic in NOTIFICATION_CHARACTERISTICS:
                await client.start_notify(
                    characteristic,
                    notification_handler(characteristic),
                )

            if plan.action == "enumerate":
                recorder.set_phase("enumeration_baseline")
                await asyncio.sleep(plan.baseline_seconds)

            recorder.set_phase("enumeration")
            start, entries = await enumerate_feature_keys(
                channel, plan.response_timeout_seconds
            )
            keys = [entry.key for entry in entries if entry.key is not None]
            manifest["enumeration"] = {
                "revision": start.revision,
                "announcedCount": start.count,
                "keys": keys,
                "targetPresent": TARGET_FEATURE_KEY in keys,
            }

            if plan.action == "enable":
                if not plan.allows_persistent_write:
                    raise ProbeRefusal(
                        "persistent write reached without both opt-ins"
                    )
                pinned_keys = require_pinned_feature_enumeration(
                    peripheral_id=plan.peripheral_id,
                    start=start,
                    entries=entries,
                )
                if tuple(keys) != pinned_keys:
                    raise ProbeRefusal(
                        "same-run enumeration projection differs from its "
                        "validated pinned snapshot"
                    )
                manifest["pinnedPhysicalEnumeration"][
                    "sameRunSnapshotVerified"
                ] = True
                _atomic_json(manifest_path, manifest)
                preflight: DataRangeCursor | None = None
                if plan.banked_discovery is not None:
                    recorder.set_phase("history_empty_bank_preflight")
                    preflight = await channel.call_data_range(
                        timeout_seconds=plan.response_timeout_seconds
                    )
                    manifest["bankedDiscovery"]["preflight"] = _cursor_dict(
                        preflight
                    )
                    if preflight.write_cursor != preflight.read_cursor:
                        manifest["bankedDiscovery"]["result"] = {
                            "verdict": "blocked_preexisting_fifo_backlog",
                            "persistentWriteAttempted": False,
                            "historyACKSent": False,
                            "historyTrimSent": False,
                        }
                    require_empty_history_preflight(preflight)
                    channel.authorize_after_empty_history_preflight(preflight)
                    # Production captures require the shared response buffer to
                    # settle after 0x22 before another command is issued.
                    await asyncio.sleep(POST_RANGE_RESPONSE_SETTLE_SECONDS)

                async def attempt_persistent_set() -> dict[str, Any]:
                    recorder.set_phase("set")
                    set_status = "not_sent"
                    set_response_hex: str | None = None
                    persistent_write: dict[str, Any]
                    try:
                        response = await channel.call(
                            SET_FF_VALUE,
                            TARGET_SET_PAYLOAD,
                            plan.response_timeout_seconds,
                        )
                        set_response_hex = response.hex()
                        set_status = (
                            "exact_target_echo_observed_no_effect_claim"
                            if set_response_confirms_target(response)
                            else "response_ambiguous_no_retry"
                        )
                    except ProbeTransportError as error:
                        set_status = (
                            "write_attempted_response_missing_no_retry"
                        )
                        manifest["setError"] = str(error)
                    except BaseException as error:
                        set_status = (
                            "write_attempted_unexpected_error_no_retry"
                            if channel.set_write_attempted
                            else "write_not_attempted_unexpected_error"
                        )
                        manifest["setError"] = str(error)
                        raise
                    finally:
                        persistent_write = {
                            "attemptedExactlyOnce": (
                                channel.set_write_attempted
                            ),
                            "key": TARGET_FEATURE_KEY,
                            "value": TARGET_FEATURE_VALUE,
                            "status": set_status,
                            "responseHex": set_response_hex,
                            "priorStateKnown": False,
                            "priorStateRestorable": False,
                            "effectSuccessClaimed": False,
                        }
                        # Persist the sole write outcome before any post-write
                        # cue can fail. The finalizer may later mark the run
                        # failed, but it must never erase one-shot evidence.
                        manifest["persistentWrite"] = persistent_write
                        _atomic_json(manifest_path, manifest)
                    return persistent_write

                trial = await observe_matched_enable_trial(
                    recorder,
                    persistent_set_action=attempt_persistent_set,
                    quiet_seconds=plan.quiet_phase_seconds,
                    positive_walk_seconds=plan.positive_walk_seconds,
                    arm_motion_control_seconds=(
                        plan.arm_motion_control_seconds
                    ),
                    positive_walk_label=plan.positive_walk_label or "",
                    arm_motion_control_label=(
                        plan.arm_motion_control_label or ""
                    ),
                    operator_cue=active_operator_cue,
                )
                manifest["activityPhases"]["preEnableObserved"] = trial[
                    "preEnable"
                ]
                manifest["persistentWrite"] = trial["persistentWrite"]
                manifest["activityPhases"]["postEnableObserved"] = trial[
                    "postEnable"
                ]
                labelled_phases = trial["combinedPhases"]
                manifest["activityPhases"]["observed"] = labelled_phases
                set_status = str(trial["persistentWrite"]["status"])
                if plan.banked_discovery is not None:
                    assert preflight is not None
                    assert history_budget is not None
                    result = await observe_first_fifo_chunk(
                        channel,
                        recorder,
                        plan.banked_discovery,
                        history_budget,
                        preflight,
                        labelled_phases,
                        response_timeout_seconds=(
                            plan.response_timeout_seconds
                        ),
                    )
                    result["persistentWriteResponseStatus"] = set_status
                    manifest["bankedDiscovery"]["result"] = result
                    if not result["cursorSpaceUnchanged"]:
                        raise ProbeTransportError(
                            "postflight cursor space changed without ACK"
                        )
            else:
                recorder.set_phase("enumeration_after")
                await asyncio.sleep(plan.post_seconds)
            manifest["status"] = "capture_completed_evaluation_pending"
    except Exception as error:
        manifest["status"] = "failed"
        manifest["errorType"] = type(error).__name__
        manifest["error"] = str(error)
        raise
    finally:
        summary = recorder.summary()
        recorder.close()
        if plan.action == "enable":
            manifest["labelledActivityComparison"] = (
                compare_labelled_activity(summary)
            )
            manifest["status"] = (
                "capture_completed_no_success_claim"
                if manifest.get("status") == "capture_completed_evaluation_pending"
                else manifest.get("status")
            )
        _atomic_json(summary_path, summary)
        manifest["completedAt"] = datetime.now(timezone.utc).isoformat()
        manifest["packetSummary"] = summary
        if channel is not None:
            manifest["setWriteAttempted"] = channel.set_write_attempted
        _atomic_json(manifest_path, manifest)
    return manifest


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "The set action is persistent and the prior value is unknowable. "
            "There is intentionally no rollback command."
        ),
    )
    subparsers = parser.add_subparsers(dest="action", required=True)

    def common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument(
            "--peripheral-id",
            required=True,
            help="exact CoreBluetooth UUID; names/fuzzy matching are refused",
        )
        subparser.add_argument("--output-dir", required=True, type=Path)
        subparser.add_argument(
            "--response-timeout-seconds", type=float, default=5.0
        )

    enumerate_parser = subparsers.add_parser(
        "enumerate",
        help="read only the strap's feature-key names using 0x75/0x76",
    )
    common(enumerate_parser)
    enumerate_parser.add_argument(
        "--baseline-seconds", type=float, default=0.0
    )
    enumerate_parser.add_argument("--post-seconds", type=float, default=0.0)

    enable_parser = subparsers.add_parser(
        "enable",
        help=(
            "persist enable_false_step_detection=1 once, after the pinned "
            "enumeration proof "
            "and two exact acknowledgements"
        ),
    )
    common(enable_parser)
    enable_parser.set_defaults(baseline_seconds=0.0, post_seconds=0.0)
    enable_parser.add_argument(
        "--ack-unknown-prior-state",
        metavar="PHRASE",
        help=f"must be exactly: {UNKNOWN_STATE_ACK!r}",
    )
    enable_parser.add_argument(
        "--authorize-persistent-write",
        metavar="PHRASE",
        help=f"must be exactly: {PERSISTENT_WRITE_ACK!r}",
    )
    enable_parser.add_argument(
        "--positive-walk-label",
        required=True,
        help=(
            "explicit operator label for the real-walking comparison phase "
            "(for example counted_walk_500)"
        ),
    )
    enable_parser.add_argument(
        "--arm-motion-control-label",
        required=True,
        help=(
            "explicit operator label for the planted-feet arm-motion control "
            "phase"
        ),
    )
    enable_parser.add_argument(
        "--quiet-phase-seconds",
        type=float,
        default=DEFAULT_QUIET_PHASE_SECONDS,
    )
    enable_parser.add_argument(
        "--positive-walk-seconds",
        type=float,
        default=DEFAULT_ACTIVITY_PHASE_SECONDS,
    )
    enable_parser.add_argument(
        "--arm-motion-control-seconds",
        type=float,
        default=DEFAULT_ACTIVITY_PHASE_SECONDS,
    )
    enable_parser.add_argument(
        "--operator-cues",
        action="store_true",
        required=True,
        help=(
            "required: on macOS, speak fixed ready/boundary/phase cues with "
            "/usr/bin/say; activity labels are never spoken"
        ),
    )
    enable_parser.add_argument(
        "--banked-discovery",
        action="store_true",
        required=True,
        help=(
            "required: enforce empty W==U preflight and the unchanged 2-second "
            "settle, then observe only the first unacknowledged 0x16/00 FIFO "
            "chunk with abort and cursor postflight"
        ),
    )
    enable_parser.add_argument(
        "--history-observation-seconds",
        type=float,
        default=30.0,
        help="strict post-write history observation cap, at most 75 seconds",
    )
    enable_parser.add_argument(
        "--history-byte-cap",
        type=int,
        default=1_000_000,
        help=(
            "strict DATA_FROM_STRAP byte cap; command responses remain "
            "admissible for ABORT/postflight, at most 8388608"
        ),
    )
    return parser


def plan_from_args(args: argparse.Namespace) -> ProbePlan:
    return validate_plan(
        action=args.action,
        peripheral_id=args.peripheral_id,
        output_dir=args.output_dir,
        baseline_seconds=args.baseline_seconds,
        post_seconds=args.post_seconds,
        response_timeout_seconds=args.response_timeout_seconds,
        unknown_state_ack=getattr(args, "ack_unknown_prior_state", None),
        persistent_write_ack=getattr(
            args, "authorize_persistent_write", None
        ),
        positive_walk_label=getattr(args, "positive_walk_label", None),
        arm_motion_control_label=getattr(
            args, "arm_motion_control_label", None
        ),
        quiet_phase_seconds=getattr(
            args, "quiet_phase_seconds", DEFAULT_QUIET_PHASE_SECONDS
        ),
        positive_walk_seconds=getattr(
            args, "positive_walk_seconds", DEFAULT_ACTIVITY_PHASE_SECONDS
        ),
        arm_motion_control_seconds=getattr(
            args,
            "arm_motion_control_seconds",
            DEFAULT_ACTIVITY_PHASE_SECONDS,
        ),
        banked_discovery=getattr(args, "banked_discovery", False),
        history_observation_seconds=getattr(
            args, "history_observation_seconds", 30.0
        ),
        history_byte_cap=getattr(args, "history_byte_cap", 1_000_000),
        operator_cues=getattr(args, "operator_cues", False),
    )


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        plan = plan_from_args(args)
    except ProbeRefusal as error:
        parser.error(str(error))
    if plan.action == "enable":
        print(
            "WARNING: this sends one persistent feature write. "
            "The prior state is unreadable and cannot be restored exactly.",
            file=sys.stderr,
        )
        print(
            "Only enable_false_step_detection=1 is reachable; "
            "ASCII 1 semantics and any filtering effect remain unproven; "
            "the required first-FIFO-chunk history trace cannot ACK or trim; "
            "no clock, reboot, mode, or other feature command exists.",
            file=sys.stderr,
        )
    try:
        asyncio.run(run_probe(plan))
    except (ProbeRefusal, ProbeTransportError) as error:
        print(f"probe failed closed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
