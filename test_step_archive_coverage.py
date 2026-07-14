import csv
import importlib.util
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


def encode_r10(device_timestamp: int) -> str:
    payload = bytearray(MODULE.R10_MINIMUM_PAYLOAD_BYTES)
    payload[:2] = b"\x2b\x0a"
    payload[7:11] = device_timestamp.to_bytes(4, "little")
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


if __name__ == "__main__":
    unittest.main()
