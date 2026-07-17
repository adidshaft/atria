import csv
import importlib.util
import sys
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "replay_sensor_reference", ROOT / "tools" / "replay_sensor_reference.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


REAL_FRAME = (
    "2026-07-02 02:39:21.624 Atria[123:456] ATRIADBG frame ch=61080005 len=104 hex="
    "aa6400a12f1805072a2b01db542a6a081a80549001770000000000000000000060bc09ce00ee253c"
    "0008dc3e0a87643ee14a6c3f00001c460008dc3e0a87643ee14a6c3f7902b9029703b6028001900b"
    "010c020c000000000008000148020000000000005fa568b1"
)


class SensorReferenceReplayTests(unittest.TestCase):
    def test_crc_valid_real_frame_extracts_neutral_offset_fields(self):
        frame = MODULE.parse_frame_line(REAL_FRAME)

        self.assertIsNotNone(frame)
        self.assertEqual(frame.record_version, 24)
        self.assertEqual(frame.payload_length, 96)
        self.assertEqual(frame.raw_u16_64, 633)
        self.assertEqual(frame.raw_u16_66, 697)
        self.assertEqual(frame.raw_u16_68, 919)
        self.assertTrue(frame.transport_validated)

    def test_corrupt_crc_wrong_version_and_short_payload_are_rejected(self):
        corrupt = REAL_FRAME[:-1] + ("0" if REAL_FRAME[-1] != "0" else "1")
        self.assertIsNone(MODULE.parse_frame_line(corrupt))

        timestamp = "2026-07-02T02:39:21.624"
        wrong_version = bytes([0x2F, 99]) + bytes(68)
        short = bytes([0x2F, 24]) + bytes(67)
        self.assertIsNone(MODULE.parse_frame_line(f"{timestamp},{wrong_version.hex()}"))
        self.assertIsNone(MODULE.parse_frame_line(f"{timestamp},{short.hex()}"))

    def test_reference_pairing_is_nearest_and_tolerance_bounded(self):
        frame = MODULE.parse_frame_line(REAL_FRAME)
        assert frame is not None
        references = [
            MODULE.ReferenceRow(frame.timestamp - timedelta(seconds=1.5), 97.0, None, "older"),
            MODULE.ReferenceRow(frame.timestamp + timedelta(seconds=0.4), 98.0, None, "nearer"),
        ]

        matches = MODULE.pair_nearest([frame], references, max_age_s=1.0)
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0].reference.label, "nearer")
        self.assertAlmostEqual(matches[0].age_s, 0.4)
        self.assertEqual(MODULE.pair_nearest([frame], references, max_age_s=0.3), [])

    def test_export_and_summary_remain_research_only(self):
        frame = MODULE.parse_frame_line(REAL_FRAME)
        assert frame is not None
        summary = MODULE.summarize([frame], [], 2.0)

        self.assertEqual(summary["status"], "research_unvalidated")
        self.assertEqual(summary["decoder_validated"], "0")
        self.assertEqual(summary["metric_promotions"], "0")
        self.assertNotIn("spo2_percent", summary)
        self.assertNotIn("skin_temp_c", summary)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "candidates.csv"
            MODULE.export_frames(output, [frame])
            with output.open(newline="") as handle:
                rows = list(csv.DictReader(handle))
        self.assertEqual(rows[0]["raw_u16_64"], "633")
        self.assertEqual(rows[0]["raw_u16_68"], "919")
        self.assertNotIn("spo2_percent", rows[0])
        self.assertNotIn("skin_temp_c", rows[0])

    def test_reference_csv_requires_timestamp_and_at_least_one_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "reference.csv"
            path.write_text(
                "timestamp,reference_spo2_percent,reference_skin_temp_c,label\n"
                "2026-07-02T02:39:21.000,98,,baseline\n"
                "bad,97,33.1,invalid-time\n"
                "2026-07-02T02:39:22.000,,,empty\n",
                encoding="utf-8",
            )
            rows = MODULE.parse_reference(path)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].spo2_percent, 98.0)
        self.assertEqual(rows[0].label, "baseline")


if __name__ == "__main__":
    unittest.main()
