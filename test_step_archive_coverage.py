import csv
import hashlib
import importlib.util
import json
import math
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from zoneinfo import ZoneInfo


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "summarize_step_archive_coverage", ROOT / "tools" / "summarize_step_archive_coverage.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

PREFLIGHT_SPEC = importlib.util.spec_from_file_location(
    "summarize_step_calibration_preflight",
    ROOT / "tools" / "summarize_step_calibration_preflight.py",
)
PREFLIGHT = importlib.util.module_from_spec(PREFLIGHT_SPEC)
assert PREFLIGHT_SPEC.loader is not None
sys.modules[PREFLIGHT_SPEC.name] = PREFLIGHT
PREFLIGHT_SPEC.loader.exec_module(PREFLIGHT)


def encode_r10(device_timestamp: int, gait_sample_offset: int | None = None) -> str:
    payload = bytearray(MODULE.R10_MINIMUM_PAYLOAD_BYTES)
    payload[:2] = b"\x2b\x0a"
    payload[7:11] = device_timestamp.to_bytes(4, "little")
    if gait_sample_offset is not None:
        for sample in range(100):
            phase = 2 * math.pi * 2 * (gait_sample_offset + sample) / 100
            acceleration_x = round(4096 + 655 * math.sin(phase))
            gyroscope_x = round(30 * math.sin(phase))
            payload[85 + sample * 2:87 + sample * 2] = acceleration_x.to_bytes(
                2, "little", signed=True
            )
            payload[688 + sample * 2:690 + sample * 2] = gyroscope_x.to_bytes(
                2, "little", signed=True
            )
    declared = len(payload) + 4
    length = declared.to_bytes(2, "little")
    raw = b"\xaa" + length + bytes([MODULE.crc8(length)]) + payload
    raw += (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "little")
    return raw.hex()


def write_archive(path: Path, rows: list[tuple[int, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(("schema_version", "received_at_unix_ms", "source", "packet_type", "record_type", "raw_frame_hex"))
        for received_ms, raw_hex in rows:
            writer.writerow((2, received_ms, "stream5", "2b", "0a", raw_hex))


class StepArchiveCoverageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.replay_build = tempfile.TemporaryDirectory()
        cls.replay_binary = Path(cls.replay_build.name) / "replay_step_calibration"
        subprocess.run(
            [
                "swiftc",
                "-O",
                str(ROOT / "tools" / "replay_step_calibration.swift"),
                str(ROOT / "Atria" / "Atria" / "AtriaR10Motion.swift"),
                str(ROOT / "Atria" / "Atria" / "FrameParser.swift"),
                "-o",
                str(cls.replay_binary),
            ],
            check=True,
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.replay_build.cleanup()

    def test_crc_and_layout_are_required(self):
        raw = encode_r10(42)
        decoded = MODULE.decode_r10(1_000, raw)
        self.assertIsNotNone(decoded)
        self.assertEqual(decoded.device_timestamp, 42)

        corrupt = raw[:-1] + ("0" if raw[-1] != "0" else "1")
        self.assertIsNone(MODULE.decode_r10(1_000, corrupt))
        self.assertIsNone(MODULE.decode_r10(1_000, "aa00"))

    def test_recursive_pull_copies_and_device_timestamps_are_deduplicated(self):
        rows = [(1_000, encode_r10(1)), (2_000, encode_r10(2))]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_archive(root / "pull-a" / "archive.csv", rows)
            write_archive(root / "pull-b" / "archive.csv", rows + [(2_500, encode_r10(2))])
            loaded, parsed, copied = MODULE.load_rows(root)
            decoded, device_duplicates = MODULE.decoded_unique_frames(loaded)

        self.assertEqual(parsed, 5)
        self.assertEqual(copied, 2)
        self.assertEqual(len(loaded), 3)
        self.assertEqual(len(decoded), 2)
        self.assertEqual(device_duplicates, 1)

    def test_complete_second_precision_counted_window_can_be_ready(self):
        frames = [
            MODULE.DecodedFrame(received_ms, index, str(index))
            for index, received_ms in enumerate((0, 1_000, 2_000, 3_000))
        ]
        window = MODULE.Window("counted", 0, 3_000, 3, "second")
        summary = MODULE.summarize_window(window, frames, [window])

        self.assertEqual(summary["decoded_unique_frames"], "3")
        self.assertEqual(summary["decoded_samples"], "300")
        self.assertEqual(summary["sample_coverage_percent"], "100.000")
        self.assertEqual(summary["device_contiguous_segments"], "1")
        self.assertEqual(summary["step_calibration_ready"], "1")

    def test_rest_zero_is_explicit_and_end_boundary_remains_exclusive(self):
        timezone = ZoneInfo("UTC")
        window = MODULE.parse_window("Rest before,0,3000,0,second", timezone)
        frames = [
            MODULE.DecodedFrame(index * 1_000, index, str(index))
            for index in range(4)
        ]
        summary = MODULE.summarize_window(window, frames, [window])

        self.assertEqual(window.expected_steps, 0)
        self.assertEqual(summary["expected_steps"], "0")
        self.assertEqual(summary["decoded_unique_frames"], "3")
        self.assertEqual(summary["last_device_timestamp"], "2")
        self.assertNotIn("missing_counted_steps", summary["reason"])

    def test_ninety_four_percent_contiguous_prefix_still_fails_closed(self):
        frames = [MODULE.DecodedFrame(index * 1_000, index, str(index)) for index in range(94)]
        window = MODULE.Window("walk", 0, 100_000, 100, "second")
        summary = MODULE.summarize_window(window, frames, [window])

        self.assertEqual(summary["sample_coverage_percent"], "94.000")
        self.assertEqual(summary["step_calibration_ready"], "0")
        self.assertIn("sample_coverage_below_95_percent", summary["reason"])
        self.assertIn("uncovered_device_sample_time", summary["reason"])

    def test_swift_fitter_and_replay_share_strict_device_time_contract(self):
        fitter = (ROOT / "tools" / "fit_step_calibration.swift").read_text()
        replay = (ROOT / "tools" / "replay_step_calibration.swift").read_text()

        self.assertIn("coverage >= 0.95", fitter)
        self.assertIn("maximumUncoveredGapMS == 0", fitter)
        self.assertIn("sampleAtMS < windows[index].endMS", fitter)
        self.assertIn("manifest must contain the exact six-stage guided calibration sequence", fitter)
        self.assertIn("previous.endMS <= next.startMS", fitter)
        self.assertIn("window.endMS - window.startMS >= 60_000", fitter)
        self.assertIn("validatedDeviceTimestamp(frame: frame)", replay)
        self.assertIn("sampleAtMS < endMS", replay)
        self.assertIn("duplicate_frames=", replay)
        self.assertIn("magnitudeSegments", replay)
        self.assertIn("decoded.deviceTimestamp &- previousDeviceTimestamp != 1", replay)
        self.assertIn("magnitudeSegments.reduce(0)", replay)
        for source in (fitter, replay):
            self.assertIn("FileHandle(forReadingFrom: file)", source)
            self.assertIn("read(upToCount: 64 * 1_024)", source)
            self.assertIn("hexNibble", source)
            self.assertNotIn("String(contentsOf: file", source)

    def test_replay_applies_complete_arbitrary_fitter_candidate_to_rest_window(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "archive.csv"
            write_archive(archive, [(100_000, encode_r10(100))])
            legacy = subprocess.run(
                [str(self.replay_binary), directory, "100000", "101000", "0"],
                capture_output=True,
                text=True,
            )
            result = subprocess.run(
                [
                    str(self.replay_binary),
                    directory,
                    "100000",
                    "101000",
                    "0",
                    "--candidate-filter",
                    "12",
                    "--candidate-peak",
                    "37",
                    "--candidate-sensitivity",
                    "0.14",
                    "--candidate-confirmation",
                    "10",
                    "--candidate-gain",
                    "1.25",
                ],
                capture_output=True,
                text=True,
            )

        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertIn("production_steps=0", legacy.stdout)
        self.assertIn(
            "gait_shadow_overlapping_windows=0 window_s=5 stride_s=1 accepted_overlapping_windows=0 accepted_ratio=0.0000",
            legacy.stdout,
        )
        self.assertIn("activity_decoder_validated=0 production_label=none", legacy.stdout)
        self.assertNotIn("candidate_override=", legacy.stdout)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "candidate_override=1 filter=12 peak=37 sensitivity=0.14 confirmation=10 gain=1.2500",
            result.stdout,
        )
        self.assertIn("candidate_raw_steps=0 candidate_steps=0", result.stdout)
        self.assertIn(
            "candidate_expected_steps=0 scoreable=1 rest_false_steps=0 rest_pass=1",
            result.stdout,
        )

    def test_replay_gait_shadow_counts_overlapping_stride_windows_and_resets_at_gap(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "archive.csv"
            timestamps = list(range(100, 107)) + list(range(108, 114))
            rows = [
                (timestamp * 1_000, encode_r10(timestamp, index * 100))
                for index, timestamp in enumerate(timestamps)
            ]
            write_archive(archive, rows)
            result = subprocess.run(
                [str(self.replay_binary), directory, "100000", "114000", "0"],
                capture_output=True,
                text=True,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("continuity_breaks=1", result.stdout)
        self.assertIn(
            "gait_shadow_overlapping_windows=5 window_s=5 stride_s=1 "
            "accepted_overlapping_windows=5 accepted_ratio=1.0000 "
            "longest_accepted_stride_run_s=3",
            result.stdout,
        )
        self.assertIn("accepted_cadence_median_spm=120.00", result.stdout)
        self.assertIn("activity_decoder_validated=0 production_label=none", result.stdout)

    def test_replay_rejects_partial_malformed_and_out_of_grid_candidate_options(self):
        base = [str(self.replay_binary), "/tmp", "100000", "101000", "0"]
        partial = subprocess.run(
            base + ["--candidate-filter", "8"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(partial.returncode, 2)
        self.assertIn("requires all five candidate options", partial.stderr)

        out_of_grid = subprocess.run(
            base
            + [
                "--candidate-filter",
                "5",
                "--candidate-peak",
                "29",
                "--candidate-sensitivity",
                "0.06",
                "--candidate-confirmation",
                "6",
                "--candidate-gain",
                "1.11",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(out_of_grid.returncode, 2)
        self.assertIn("candidate filter must be one of", out_of_grid.stderr)

        nonfinite = subprocess.run(
            base
            + [
                "--candidate-filter",
                "8",
                "--candidate-peak",
                "29",
                "--candidate-sensitivity",
                "0.06",
                "--candidate-confirmation",
                "6",
                "--candidate-gain",
                "nan",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(nonfinite.returncode, 2)
        self.assertIn("candidate gain must be finite", nonfinite.stderr)

    def test_candidate_replay_refuses_incomplete_motion_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "archive.csv"
            write_archive(archive, [(100_000, encode_r10(100))])
            result = subprocess.run(
                [
                    str(self.replay_binary), directory, "100000", "102000", "0",
                    "--candidate-filter", "8",
                    "--candidate-peak", "29",
                    "--candidate-sensitivity", "0.06",
                    "--candidate-confirmation", "6",
                    "--candidate-gain", "1.11",
                ],
                capture_output=True,
                text=True,
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("evidence_scoreable=0", result.stdout)
        self.assertIn("candidate replay refused incomplete motion evidence", result.stderr)

    def test_device_timestamp_gap_splits_coverage_segments(self):
        frames = [
            MODULE.DecodedFrame(10_000, 0, "a"),
            MODULE.DecodedFrame(11_000, 1, "b"),
            MODULE.DecodedFrame(20_000, 3, "c"),
        ]
        window = MODULE.Window("counted", 0, 4_000, 3, "second")
        summary = MODULE.summarize_window(window, frames, [window])

        self.assertEqual(summary["device_contiguous_segments"], "2")
        self.assertEqual(summary["device_timestamp_continuity_breaks"], "1")
        self.assertEqual(summary["longest_contiguous_samples"], "200")
        self.assertEqual(summary["step_calibration_ready"], "0")
        self.assertIn("device_timestamp_discontinuity", summary["reason"])

    def test_missing_archive_and_minute_overlap_fail_closed(self):
        first = MODULE.Window("normal", 0, 60_000, None, "minute")
        second = MODULE.Window("brisk", 20_000, 40_000, 100, "minute")
        summaries = [
            MODULE.summarize_window(window, [], [first, second])
            for window in (first, second)
        ]

        self.assertEqual(summaries[0]["step_calibration_ready"], "0")
        self.assertIn("missing_counted_steps", summaries[0]["reason"])
        self.assertEqual(summaries[1]["overlaps_supplied_window"], "1")
        self.assertIn("overlaps_supplied_window", summaries[1]["reason"])
        self.assertIn("timing_not_second_precision", summaries[1]["reason"])
        self.assertIn("sample_coverage_below_95_percent", summaries[1]["reason"])

    def test_iso_times_default_to_requested_timezone(self):
        timezone = ZoneInfo("Asia/Kolkata")
        window = MODULE.parse_window(
            "walk,2026-07-11T15:20:00,2026-07-11T15:21:00,100,minute", timezone
        )
        self.assertEqual(window.duration_s, 60)
        self.assertEqual(window.timing_precision, "minute")

    def test_retention_forecast_uses_source_cap_peak_hour_and_segment_reserve(self):
        source = (ROOT / "Atria" / "Atria" / "AtriaStrapCalibrationArchive.swift").read_text()
        capacity, maximum_file = PREFLIGHT.discover_capacity(source)
        self.assertEqual(capacity, 96 * 1_024 * 1_024)
        self.assertEqual(maximum_file, 32 * 1_024 * 1_024)

        observations = [
            (1_000_000 + index * 5 * 60_000, 1_000_000)
            for index in range(7 * 12 + 1)
        ]
        forecast = PREFLIGHT.retention_forecast(
            observations,
            total_archive_bytes=90 * 1_024 * 1_024,
            archive_source=source,
        )

        self.assertEqual(forecast["step_calibration_archive_retention_forecast_status"], "sufficient")
        self.assertEqual(forecast["step_calibration_archive_retention_capacity_bytes"], str(capacity))
        self.assertEqual(forecast["step_calibration_archive_retention_maximum_file_bytes"], str(maximum_file))
        self.assertEqual(forecast["step_calibration_archive_recent_ingress_bytes_per_hour"], "13000000.000")
        self.assertAlmostEqual(
            float(forecast["step_calibration_archive_estimated_retained_hours"]),
            (64 * 1_024 * 1_024) / 13_000_000,
            places=3,
        )
        self.assertEqual(
            forecast["step_calibration_archive_retention_action"],
            "pull_no_later_than_2h_after_final_calibration_window",
        )

    def test_retention_forecast_fails_closed_for_short_or_incomplete_evidence(self):
        source = (ROOT / "Atria" / "Atria" / "AtriaStrapCalibrationArchive.swift").read_text()
        fast_observations = [
            (1_000_000 + index * 60_000, 2_000_000)
            for index in range(7 * 60 + 1)
        ]
        too_short = PREFLIGHT.retention_forecast(
            fast_observations,
            total_archive_bytes=95 * 1_024 * 1_024,
            archive_source=source,
        )
        self.assertEqual(too_short["step_calibration_archive_retention_forecast_status"], "too_short")
        self.assertEqual(
            too_short["step_calibration_archive_retention_risk"],
            "newest_rows_may_rotate_before_2h_delayed_pull",
        )
        self.assertEqual(
            too_short["step_calibration_archive_retention_action"],
            "pull_immediately_after_each_calibration_window",
        )

        insufficient = PREFLIGHT.retention_forecast(
            fast_observations,
            total_archive_bytes=1,
            archive_source=source,
            invalid_timestamp_rows=1,
        )
        self.assertEqual(
            insufficient["step_calibration_archive_retention_forecast_status"],
            "insufficient_evidence",
        )
        self.assertEqual(
            insufficient["step_calibration_archive_estimated_retained_hours"],
            "-1.000",
        )
        self.assertIn(
            "invalid_timestamp_rows",
            insufficient["step_calibration_archive_retention_evidence_reason"],
        )

        unknown_cap = PREFLIGHT.retention_forecast(
            fast_observations,
            total_archive_bytes=1,
            archive_source="",
        )
        self.assertEqual(unknown_cap["step_calibration_archive_retention_capacity_status"], "unknown")
        self.assertEqual(
            unknown_cap["step_calibration_archive_retention_forecast_status"],
            "insufficient_evidence",
        )
        self.assertIn(
            "capacity_not_discoverable",
            unknown_cap["step_calibration_archive_retention_evidence_reason"],
        )

    def test_step_calibration_sequence_preferences_are_validated_without_ui_claim(self):
        absent = PREFLIGHT.sequence_summary(None)
        self.assertEqual(absent["step_calibration_sequence_state"], "not_started")
        self.assertEqual(absent["step_calibration_sequence_completed_window_count"], "0")
        self.assertEqual(absent["step_calibration_sequence_state_source"], "preferences_absent_default")
        self.assertEqual(absent["step_calibration_sequence_ui_visibility_proven"], "0")

        active_state = {
            "version": 1,
            "sessionStartedMS": 100,
            "activeStageIndex": 1,
            "activeStageStartMS": 200_000,
            "windows": [
                {
                    "label": "Rest before",
                    "kind": "rest",
                    "start_ms": 100_000,
                    "end_ms": 160_000,
                    "expected_steps": 0,
                }
            ],
        }
        active = PREFLIGHT.sequence_summary(active_state)
        self.assertEqual(active["step_calibration_sequence_state"], "active")
        self.assertEqual(active["step_calibration_sequence_completed_window_count"], "1")
        self.assertEqual(active["step_calibration_sequence_active"], "1")
        self.assertEqual(active["step_calibration_sequence_state_source"], "preferences_persisted")

        finishing_state = dict(active_state)
        finishing_state["activeStageFinishRequestedMS"] = 202_000
        finishing = PREFLIGHT.sequence_summary(finishing_state)
        self.assertEqual(finishing["step_calibration_sequence_state"], "finishing")
        self.assertEqual(finishing["step_calibration_sequence_finishing"], "1")

        corrupt = PREFLIGHT.sequence_summary(b"not-json")
        self.assertEqual(corrupt["step_calibration_sequence_state"], "corrupt")
        self.assertEqual(corrupt["step_calibration_sequence_completed_window_count"], "-1")
        self.assertEqual(corrupt["step_calibration_sequence_state_source"], "preferences_corrupt")

        complete_windows = []
        cursor = 1_000_000
        for label, kind, expected, minimum_duration in PREFLIGHT._STAGES:
            duration = max(minimum_duration, 65_000 if kind == "rest" else 20_000)
            complete_windows.append(
                {
                    "label": label,
                    "kind": kind,
                    "start_ms": cursor,
                    "end_ms": cursor + duration,
                    "expected_steps": expected,
                }
            )
            cursor += duration + 2_000
        complete_state = {
            "version": 1,
            "sessionStartedMS": 1_000_000,
            "activeStageIndex": None,
            "activeStageStartMS": None,
            "activeStageFinishRequestedMS": None,
            "windows": complete_windows,
        }
        complete = PREFLIGHT.sequence_summary(json.dumps(complete_state).encode("utf-8"))
        self.assertEqual(complete["step_calibration_sequence_state"], "complete")
        self.assertEqual(
            PREFLIGHT.completed_sequence_manifest(complete_state),
            {"windows": complete_windows},
        )

        overlapping = json.loads(json.dumps(complete_state))
        overlapping["windows"][1]["start_ms"] = overlapping["windows"][0]["end_ms"] - 1
        self.assertEqual(
            PREFLIGHT.sequence_summary(overlapping)["step_calibration_sequence_state"],
            "corrupt",
        )
        with self.assertRaises(ValueError):
            PREFLIGHT.completed_sequence_manifest(overlapping)

        unknown_key = json.loads(json.dumps(complete_state))
        unknown_key["windows"][0]["unexpected"] = True
        self.assertEqual(
            PREFLIGHT.sequence_summary(unknown_key)["step_calibration_sequence_state"],
            "corrupt",
        )

        boolean_timestamp = json.loads(json.dumps(complete_state))
        boolean_timestamp["windows"][0]["start_ms"] = True
        self.assertEqual(
            PREFLIGHT.sequence_summary(boolean_timestamp)["step_calibration_sequence_state"],
            "corrupt",
        )

    def test_pull_summary_wires_fail_closed_retention_and_sequence_fields(self):
        pull = (ROOT / "pull_atria_state.sh").read_text()
        for needle in (
            '"$(dirname "$0")/tools/summarize_step_calibration_preflight.py"',
            "step_calibration_archive_recent_ingress_bytes_per_hour",
            "step_calibration_archive_estimated_retained_hours",
            "step_calibration_archive_retention_forecast_status",
            "step_calibration_archive_retention_action",
            'prefs.get("atria.stepCalibration.sequence.v1")',
            "step_calibration_sequence_ui_visibility_proven",
            "step-calibration-manifest.json",
            "completed_sequence_manifest(raw_state)",
            "step_calibration_manifest_sha256",
            'copy_from_container "Documents/atria-captures"',
            'copy_from_container "Library/Application Support/Atria/pending-workout-intent-v1.json"',
            'copy_from_container "Library/Application Support/Atria/active-workout-route.json"',
            'copy_from_container "Library/Application Support/Atria/active-workout-route.points.ndjson"',
            'copy_from_container "Library/Application Support/Atria/pending-workout-route-transaction.json"',
            'copy_from_container "Library/Application Support/atria-strap-step-ledger.json"',
            'copy_from_container "Documents/atria-workout-routes"',
            "authoritative-runtime-state.sha256",
            '"explicit_sensor_captures"',
            "atria-captures.sha256",
            "explicit_sensor_captures_file_count",
            "Evidence directory must be new or empty",
        ):
            self.assertIn(needle, pull)

    def test_pull_help_lists_captures_and_nonempty_destination_fails_before_device_access(self):
        help_result = subprocess.run(
            [str(ROOT / "pull_atria_state.sh"), "--help"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("atria-captures/ plus SHA-256 manifest", help_result.stdout)

        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "occupied"
            destination.mkdir()
            (destination / "stale.txt").write_text("stale", encoding="utf-8")
            result = subprocess.run(
                [
                    str(ROOT / "pull_atria_state.sh"),
                    "--device", "fake-device",
                    "--evidence-dir", str(destination),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 73)
        self.assertIn("Evidence directory must be new or empty", result.stderr)

    def test_pull_copies_captures_runtime_authorities_and_recovers_complete_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device_root = root / "device"
            captures = device_root / "Documents" / "atria-captures"
            (captures / "nested").mkdir(parents=True)
            expected = {
                "oxygen.jsonl": b'{"metric":"oxygen","source":"2A37"}\n',
                "nested/temperature.bin": bytes(range(32)),
            }
            for relative, payload in expected.items():
                path = captures / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)

            point = {
                "latitude": 28.6139,
                "longitude": 77.2090,
                "altitude": 220.0,
                "timestamp": "2026-07-15T12:00:01Z",
                "horizontalAccuracy": 4.0,
                "startsNewSegment": True,
            }
            runtime_values = {
                "pending-workout-intent-v1.json": {
                    "startedAt": 805_000_000.0,
                    "endedAt": None,
                    "activityType": "walk",
                    "strengthSets": [],
                    "excludedIntervals": [],
                    "startingStepCount": 100,
                    "pausedStepCount": 0,
                    "stepAccountingIsComplete": True,
                    "startingDayStrain": 1.2,
                    "persistenceRevision": 3,
                },
                "active-workout-route.json": {
                    "schema": 1,
                    "activityType": "walk",
                    "startedAt": "2026-07-15T12:00:00Z",
                    "points": [],
                    "distanceMeters": 12.0,
                    "elevationGainMeters": 1.0,
                    "accumulatedPauseDuration": 0.0,
                    "updatedAt": "2026-07-15T12:00:02Z",
                    "persistedPointCount": 1,
                },
                "pending-workout-route-transaction.json": {
                    "schema": 1,
                    "operation": "edit",
                    "oldWorkoutID": "workout-old",
                    "createdAt": "2026-07-15T12:00:03Z",
                },
                "atria-strap-step-ledger.json": {
                    "schema": 1,
                    "segmentID": "A7F01BB5-46CA-448C-B7E0-E1D58D793D49",
                    "segmentStartedAt": 805_000_000.0,
                    "updatedAt": 805_000_004.0,
                    "segmentSteps": 23,
                    "segmentRawSteps": 21,
                    "cumulativeSteps": 123,
                    "cumulativeRawSteps": 121,
                    "deviceTimestamp": 1_784_000_000,
                    "state": "confirmed",
                },
                "atria-workout-routes/route-1.json": {
                    "id": "route-1",
                    "workoutID": "workout-1",
                    "activityType": "walk",
                    "startedAt": "2026-07-15T12:00:00Z",
                    "endedAt": "2026-07-15T12:01:40Z",
                    "points": [point],
                    "distanceMeters": 100.0,
                    "elevationGainMeters": 2.0,
                },
            }
            runtime_expected = {
                relative: (json.dumps(value) + "\n").encode("utf-8")
                for relative, value in runtime_values.items()
            }
            runtime_expected["active-workout-route.points.ndjson"] = (
                json.dumps(point) + "\n"
            ).encode("utf-8")
            runtime_sources = {
                "pending-workout-intent-v1.json": "Library/Application Support/Atria/pending-workout-intent-v1.json",
                "active-workout-route.json": "Library/Application Support/Atria/active-workout-route.json",
                "active-workout-route.points.ndjson": "Library/Application Support/Atria/active-workout-route.points.ndjson",
                "pending-workout-route-transaction.json": "Library/Application Support/Atria/pending-workout-route-transaction.json",
                "atria-strap-step-ledger.json": "Library/Application Support/atria-strap-step-ledger.json",
                "atria-workout-routes/route-1.json": "Documents/atria-workout-routes/route-1.json",
            }
            for relative, payload in runtime_expected.items():
                path = device_root / runtime_sources[relative]
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)

            complete_windows = []
            cursor = 1_780_000_000_000
            for label, kind, expected_steps, minimum_duration in PREFLIGHT._STAGES:
                duration = max(minimum_duration, 65_000 if kind == "rest" else 20_000)
                complete_windows.append(
                    {
                        "label": label,
                        "kind": kind,
                        "start_ms": cursor,
                        "end_ms": cursor + duration,
                        "expected_steps": expected_steps,
                    }
                )
                cursor += duration + 2_000
            sequence_state = {
                "version": 1,
                "sessionStartedMS": complete_windows[0]["start_ms"],
                "activeStageIndex": None,
                "activeStageStartMS": None,
                "activeStageFinishRequestedMS": None,
                "windows": complete_windows,
            }
            preferences = device_root / "Library" / "Preferences" / "com.adidshaft.atria.plist"
            preferences.parent.mkdir(parents=True, exist_ok=True)
            with preferences.open("wb") as handle:
                plistlib.dump(
                    {"atria.stepCalibration.sequence.v1": json.dumps(sequence_state).encode("utf-8")},
                    handle,
                )

            fake_devicectl = root / "fake-devicectl"
            fake_devicectl.write_text(
                """#!/bin/sh
set -eu
root=${FAKE_DEVICE_ROOT:?}
if [ "$1" = device ] && [ "$2" = info ] && [ "$3" = processes ]; then
  printf 'Atria com.adidshaft.atria\\n'
  exit 0
fi
if [ "$1" = device ] && [ "$2" = copy ] && [ "$3" = from ]; then
  shift 3
  source_path=
  destination_path=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) source_path=$2; shift 2 ;;
      --destination) destination_path=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$source_path" ] && [ -n "$destination_path" ] || exit 2
  source_path="$root/$source_path"
  [ -e "$source_path" ] || exit 1
  mkdir -p "$(dirname "$destination_path")"
  cp -R "$source_path" "$destination_path"
  exit 0
fi
exit 2
""",
                encoding="utf-8",
            )
            fake_devicectl.chmod(0o755)
            destination = root / "evidence"
            environment = os.environ.copy()
            environment.update(
                ATRIA_DEVICETCL=str(fake_devicectl),
                FAKE_DEVICE_ROOT=str(device_root),
            )
            result = subprocess.run(
                [
                    str(ROOT / "pull_atria_state.sh"),
                    "--device", "fake-device",
                    "--evidence-dir", str(destination),
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            copied = destination / "atria-captures"
            for relative, payload in expected.items():
                self.assertEqual((copied / relative).read_bytes(), payload)

            manifest = destination / "atria-captures.sha256"
            manifest_lines = manifest.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(manifest_lines), len(expected))
            for relative, payload in expected.items():
                expected_digest = hashlib.sha256(payload).hexdigest()
                matching = [line for line in manifest_lines if line.endswith(str(copied / relative))]
                self.assertEqual(len(matching), 1, manifest_lines)
                self.assertEqual(matching[0].split()[0], expected_digest)

            summary = (destination / "pull-summary.txt").read_text(encoding="utf-8")
            self.assertIn("explicit_sensor_captures_status=ok", summary)
            self.assertIn(
                f"explicit_sensor_captures_file_count={len(expected)}",
                summary,
            )
            self.assertIn(
                f"explicit_sensor_captures_total_bytes={sum(map(len, expected.values()))}",
                summary,
            )
            self.assertIn(f"explicit_sensor_captures_manifest={manifest}", summary)

            runtime_root = destination / "authoritative-runtime-state"
            for relative, payload in runtime_expected.items():
                self.assertEqual((runtime_root / relative).read_bytes(), payload)
            runtime_manifest = destination / "authoritative-runtime-state.sha256"
            runtime_lines = runtime_manifest.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(runtime_lines), len(runtime_expected))
            for relative, payload in runtime_expected.items():
                expected_digest = hashlib.sha256(payload).hexdigest()
                matching = [
                    line for line in runtime_lines
                    if line.endswith(str(runtime_root / relative))
                ]
                self.assertEqual(len(matching), 1, runtime_lines)
                self.assertEqual(matching[0].split()[0], expected_digest)
            self.assertIn("authoritative_runtime_state_status=ok", summary)
            self.assertIn(
                f"authoritative_runtime_state_file_count={len(runtime_expected)}",
                summary,
            )
            self.assertIn(
                f"authoritative_runtime_state_total_bytes={sum(map(len, runtime_expected.values()))}",
                summary,
            )
            self.assertIn(f"authoritative_runtime_state_manifest={runtime_manifest}", summary)
            self.assertIn("runtime_evidence_validation_status=ok", summary)
            self.assertIn("runtime_active_route_point_count_consistency=ok", summary)

            recovered_manifest_path = destination / "step-calibration-manifest.json"
            self.assertEqual(
                json.loads(recovered_manifest_path.read_text(encoding="utf-8")),
                {"windows": complete_windows},
            )
            recovered_payload = recovered_manifest_path.read_bytes()
            self.assertIn("step_calibration_manifest_status=ok", summary)
            self.assertIn("step_calibration_manifest_window_count=6", summary)
            self.assertIn(
                "step_calibration_manifest_sha256="
                + hashlib.sha256(recovered_payload).hexdigest(),
                summary,
            )


if __name__ == "__main__":
    unittest.main()
