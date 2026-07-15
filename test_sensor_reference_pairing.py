import csv
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
TOOL = ROOT / "tools" / "pair_sensor_references.py"


class SensorReferencePairingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def write_references(self, rows):
        path = self.root / "references.csv"
        fieldnames = [
            "timestamp",
            "reference_spo2_percent",
            "reference_skin_temp_c",
            "label",
            "event_kind",
            "reference_device",
            "input_value",
            "input_unit",
            "measurement_site",
            "contact_state",
            "notes",
            "local_only",
            "research_only",
            "decoder_validated",
            "metric_promotions",
        ]
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            for row in rows:
                writer.writerow(row)
        return path

    def reference(self, **changes):
        row = {
            "timestamp": "2026-07-15T06:00:00.000Z",
            "reference_spo2_percent": "97",
            "reference_skin_temp_c": "",
            "label": "seated",
            "event_kind": "oxygen_reference",
            "reference_device": "Independent Oximeter",
            "input_value": "97",
            "input_unit": "percent",
            "measurement_site": "fingertip",
            "contact_state": "stable-contact",
            "notes": "",
            "local_only": "1",
            "research_only": "1",
            "decoder_validated": "0",
            "metric_promotions": "0",
        }
        row.update(changes)
        return row

    def archive_row(self, second=1784095200, **changes):
        row = {
            "schema": 3,
            "capturedAt": "2026-07-15T06:00:00Z",
            "clockCorrectionStatus": "clock_ref_present",
            "clockCorrectedUnix7": second,
            "clockDeviceRef": second,
            "clockWallRef": second,
            "clockDriftSeconds": 0,
            "source": "0x2f",
            "layoutVersion": "strap4-research",
            "sequence": 1,
            "command": 5,
            "unix7": second,
            "subsec11": 0,
            "flash13": 0,
            "payloadLength": 4,
            "rawPayloadHex": "2f180102",
            "currentSessionUsable": True,
            "metricUsable": False,
            "usabilityReason": "metric_reference_pending",
        }
        row.update(changes)
        return row

    def write_archive(self, rows):
        path = self.root / "archive.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        return path

    def run_tool(self, references, archive, output="out", *extra):
        return subprocess.run(
            [
                "python3",
                str(TOOL),
                str(references),
                str(archive),
                "--output-dir",
                str(self.root / output),
                *extra,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_pairs_only_clock_qualified_raw_evidence_without_promotion(self):
        references = self.write_references([self.reference()])
        archive = self.write_archive(
            [
                self.archive_row(),
                self.archive_row(clockCorrectionStatus="clock_ref_missing", rawPayloadHex="2f180103"),
                self.archive_row(second=1784095300, rawPayloadHex="2f180104"),
            ]
        )
        result = self.run_tool(references, archive)
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads((self.root / "out" / "sensor-reference-summary.json").read_text())
        pairs = [json.loads(line) for line in (self.root / "out" / "sensor-reference-pairs.jsonl").read_text().splitlines()]
        self.assertEqual(summary["paired_rows"], 1)
        self.assertEqual(summary["validation_status"], "not_validated")
        self.assertEqual(summary["selection_policy"], "nearest_single_frame_within_window")
        self.assertEqual(summary["window_seconds"], 2.0)
        self.assertFalse(summary["decoder_validated"])
        self.assertEqual(summary["metric_promotions"], 0)
        self.assertEqual(pairs[0]["clock_delta_ms"], 0)
        self.assertEqual(pairs[0]["input_unit"], "percent")
        self.assertEqual(pairs[0]["clock_device_ref"], 1784095200)
        self.assertFalse(pairs[0]["decoder_validated"])

    def test_missing_nearby_frame_is_explicit_not_validated(self):
        references = self.write_references([self.reference()])
        archive = self.write_archive([self.archive_row(second=1784095500)])
        result = self.run_tool(references, archive)
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads((self.root / "out" / "sensor-reference-summary.json").read_text())
        self.assertEqual(summary["paired_rows"], 0)
        self.assertEqual(
            summary["reference_summaries"][0]["pairing_status"],
            "no_clock_qualified_frame",
        )

    def test_reference_claiming_decoder_validation_fails_closed(self):
        references = self.write_references([self.reference(decoder_validated="1")])
        archive = self.write_archive([self.archive_row()])
        result = self.run_tool(references, archive)
        self.assertEqual(result.returncode, 2)
        self.assertIn("decoder_validated must remain 0", result.stderr)

    def test_invalid_measurement_and_naive_time_fail_closed(self):
        archive = self.write_archive([self.archive_row()])
        invalid_value = self.write_references([self.reference(reference_spo2_percent="970")])
        result = self.run_tool(invalid_value, archive, "out-value")
        self.assertEqual(result.returncode, 2)
        invalid_time = self.write_references([self.reference(timestamp="2026-07-15T06:00:00")])
        result = self.run_tool(invalid_time, archive, "out-time")
        self.assertEqual(result.returncode, 2)

    def test_nonempty_output_and_invalid_window_fail_closed(self):
        references = self.write_references([self.reference()])
        archive = self.write_archive([self.archive_row()])
        output = self.root / "occupied"
        output.mkdir()
        (output / "keep.txt").write_text("keep")
        result = self.run_tool(references, archive, "occupied")
        self.assertEqual(result.returncode, 2)
        result = self.run_tool(references, archive, "window", "--window-seconds", "nan")
        self.assertEqual(result.returncode, 2)

    def test_output_file_fails_closed_without_traceback(self):
        references = self.write_references([self.reference()])
        archive = self.write_archive([self.archive_row()])
        output = self.root / "output-file"
        output.write_text("preserve", encoding="utf-8")

        result = self.run_tool(references, archive, "output-file")

        self.assertEqual(result.returncode, 2)
        self.assertIn("output path must be a directory", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(output.read_text(encoding="utf-8"), "preserve")

    def test_nearest_single_frame_is_selected_and_reuse_is_reported(self):
        references = self.write_references([
            self.reference(),
            self.reference(timestamp="2026-07-15T06:00:00.500Z", label="repeat"),
        ])
        archive = self.write_archive([
            self.archive_row(second=1784095199, rawPayloadHex="2f180101"),
            self.archive_row(second=1784095200, rawPayloadHex="2f180102"),
            self.archive_row(second=1784095201, rawPayloadHex="2f180103"),
        ])

        result = self.run_tool(references, archive)

        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads((self.root / "out" / "sensor-reference-summary.json").read_text())
        pairs = [json.loads(line) for line in (self.root / "out" / "sensor-reference-pairs.jsonl").read_text().splitlines()]
        self.assertEqual(len(pairs), 2)
        self.assertEqual([pair["raw_timestamp_ms"] for pair in pairs], [1784095200000] * 2)
        self.assertEqual(summary["reused_raw_frame_assignments"], 1)
        self.assertEqual(summary["reference_summaries"][0]["candidate_frame_count"], 3)

    def test_malformed_archive_boolean_numeric_and_reference_mismatch_fail_closed(self):
        references = self.write_references([self.reference()])
        malformed = self.root / "malformed.jsonl"
        malformed.write_text("{not-json}\n", encoding="utf-8")
        result = self.run_tool(references, malformed, "malformed-out")
        self.assertEqual(result.returncode, 2)
        self.assertIn("malformed archive JSON", result.stderr)

        boolean_numeric = self.write_archive([
            self.archive_row(clockCorrectedUnix7=True),
        ])
        result = self.run_tool(references, boolean_numeric, "boolean-out")
        self.assertEqual(result.returncode, 2)
        self.assertIn("no clock-qualified raw frames", result.stderr)

        mismatch = self.write_references([
            self.reference(input_value="50"),
        ])
        valid = self.write_archive([self.archive_row()])
        result = self.run_tool(mismatch, valid, "mismatch-out")
        self.assertEqual(result.returncode, 2)
        self.assertIn("oxygen input/canonical mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
