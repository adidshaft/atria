import csv
import hashlib
import json
import subprocess
import tempfile
import unittest
import zlib
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent
TOOL = ROOT / "tools" / "build_physical_window_manifests.py"
BASE_SECOND = 1_800_000_000


def crc8(data: bytes, poly: int = 0x07) -> int:
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ poly) & 0xFF if value & 0x80 else (value << 1) & 0xFF
    return value


def encode_r10(device_second: int, variant: int = 0) -> str:
    payload = bytearray(1_288)
    payload[:2] = b"\x2b\x0a"
    payload[7:11] = device_second.to_bytes(4, "little")
    payload[20] = variant
    declared = len(payload) + 4
    length = declared.to_bytes(2, "little")
    raw = b"\xaa" + length + bytes([crc8(length)]) + payload
    raw += (zlib.crc32(payload) & 0xFFFFFFFF).to_bytes(4, "little")
    return raw.hex()


def write_archive(path: Path, seconds: list[int], ambiguous_second: int | None = None) -> None:
    path.mkdir(parents=True)
    with (path / "capture.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            (
                "schema_version",
                "received_at_unix_ms",
                "source",
                "packet_type",
                "record_type",
                "raw_frame_hex",
            )
        )
        for second in seconds:
            writer.writerow((2, second * 1_000 + 250, "stream5", "2b", "0a", encode_r10(second)))
            # A copied byte-identical frame is legal and must deduplicate without
            # turning one physical device second into two seconds of evidence.
            if second == seconds[0]:
                writer.writerow((2, second * 1_000 + 250, "stream5", "2b", "0a", encode_r10(second)))
            if second == ambiguous_second:
                writer.writerow(
                    (2, second * 1_000 + 500, "stream5", "2b", "0a", encode_r10(second, 1))
                )


def iso(second: int, milliseconds: int = 0) -> str:
    rendered = datetime.fromtimestamp(second, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    return f"{rendered}.{milliseconds:03d}Z" if milliseconds else f"{rendered}Z"


def guided_manifest() -> dict:
    second = BASE_SECOND - 1_000
    windows = []
    contract = [
        ("Rest before", "rest", 0, 60),
        ("Slow 100", "walk", 100, 50),
        ("Normal 100", "walk", 100, 50),
        ("Brisk 100", "walk", 100, 50),
        ("Normal 200", "walk", 200, 100),
        ("Rest after", "rest", 0, 60),
    ]
    for label, kind, steps, duration in contract:
        windows.append(
            {
                "label": label,
                "kind": kind,
                "start_ms": second * 1_000,
                "end_ms": (second + duration) * 1_000,
                "expected_steps": steps,
            }
        )
        second += duration + 1
    return {"windows": windows}


def valid_notes() -> dict:
    return {
        "version": 1,
        "windows": [
            {
                "label": "Holdout normal 437",
                "activity": "walk",
                "start": iso(BASE_SECOND, 125),
                "end": iso(BASE_SECOND + 40, 875),
                "use_for": ["holdout", "activity"],
                "expected_steps": 437,
            },
            {
                "label": "Typing zero",
                "activity": "typing",
                "start": iso(BASE_SECOND + 50),
                "end": iso(BASE_SECOND + 90),
                "use_for": ["holdout", "activity"],
                "expected_steps": 0,
            },
            {
                "label": "Dance diagnostic",
                "activity": "dance",
                "start": iso(BASE_SECOND + 100),
                "end": iso(BASE_SECOND + 140),
                "use_for": ["activity"],
            },
        ],
    }


def required_seconds() -> list[int]:
    return (
        list(range(BASE_SECOND + 1, BASE_SECOND + 40))
        + list(range(BASE_SECOND + 50, BASE_SECOND + 90))
        + list(range(BASE_SECOND + 100, BASE_SECOND + 140))
    )


class PhysicalWindowManifestTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.archive = self.root / "archive"
        self.notes = self.root / "notes.json"
        self.guided = self.root / "guided.json"
        self.holdout = self.root / "holdout.json"
        self.activity = self.root / "activity.json"
        self.audit = self.root / "audit.json"
        write_archive(self.archive, required_seconds())
        self.write_json(self.notes, valid_notes())
        self.write_json(self.guided, guided_manifest())

    def tearDown(self):
        self.scratch.cleanup()

    @staticmethod
    def write_json(path: Path, value: dict) -> None:
        path.write_text(json.dumps(value), encoding="utf-8")

    def run_tool(self, *, notes: Path | None = None, archive: Path | None = None):
        return subprocess.run(
            [
                "python3",
                str(TOOL),
                str(archive or self.archive),
                str(notes or self.notes),
                "--calibration-manifest",
                str(self.guided),
                "--holdout-output",
                str(self.holdout),
                "--activity-output",
                str(self.activity),
                "--audit-output",
                str(self.audit),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    def reset_outputs(self) -> None:
        for path in (self.holdout, self.activity, self.audit):
            path.unlink(missing_ok=True)

    def test_builds_exact_strict_manifests_and_hashed_alignment_audit(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)

        holdout = json.loads(self.holdout.read_text(encoding="utf-8"))
        activity = json.loads(self.activity.read_text(encoding="utf-8"))
        audit = json.loads(self.audit.read_text(encoding="utf-8"))
        self.assertEqual(set(holdout), {"windows"})
        self.assertEqual(
            holdout["windows"],
            [
                {
                    "label": "Holdout normal 437",
                    "kind": "walk",
                    "start_ms": (BASE_SECOND + 1) * 1_000,
                    "end_ms": (BASE_SECOND + 40) * 1_000,
                    "expected_steps": 437,
                },
                {
                    "label": "Typing zero",
                    "kind": "negative",
                    "start_ms": (BASE_SECOND + 50) * 1_000,
                    "end_ms": (BASE_SECOND + 90) * 1_000,
                    "expected_steps": 0,
                },
            ],
        )
        self.assertEqual(set(activity), {"version", "windows"})
        self.assertEqual(activity["version"], 1)
        self.assertEqual([window["activity"] for window in activity["windows"]], ["walk", "typing", "dance"])
        self.assertTrue(all("expected_steps" not in window for window in activity["windows"]))

        first = audit["windows"][0]
        self.assertEqual(first["source_start"], iso(BASE_SECOND, 125))
        self.assertEqual(first["source_end"], iso(BASE_SECOND + 40, 875))
        self.assertEqual(first["start_trim_ms"], 875)
        self.assertEqual(first["end_trim_ms"], 875)
        self.assertEqual(first["expected_device_frames"], 39)
        self.assertEqual(first["crc_valid_device_frames"], 39)
        self.assertEqual(first["expected_steps"], 437)
        self.assertEqual(audit["detector_executed"], 0)
        self.assertEqual(audit["detector_counts_inferred"], 0)
        self.assertEqual(audit["activity_labels_inferred"], 0)
        self.assertEqual(
            audit["outputs"]["holdout_manifest"]["sha256"],
            hashlib.sha256(self.holdout.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            audit["outputs"]["activity_manifest"]["sha256"],
            hashlib.sha256(self.activity.read_bytes()).hexdigest(),
        )
        archived = audit["inputs"]["archive_files"]
        self.assertEqual([entry["path"] for entry in archived], ["capture.csv"])
        self.assertEqual(
            archived[0]["sha256"], hashlib.sha256((self.archive / "capture.csv").read_bytes()).hexdigest()
        )

    def test_rejects_schema_boolean_naive_duplicate_and_count_mistakes(self):
        cases = []

        boolean_version = valid_notes()
        boolean_version["version"] = True
        cases.append((json.dumps(boolean_version), "version must be an integer"))

        naive = valid_notes()
        naive["windows"][0]["start"] = "2027-01-15T08:00:00"
        cases.append((json.dumps(naive), "explicit UTC offset"))

        unknown = valid_notes()
        unknown["windows"][0]["guess"] = 1
        cases.append((json.dumps(unknown), "missing or unknown fields"))

        duplicate_use = valid_notes()
        duplicate_use["windows"][0]["use_for"] = ["holdout", "holdout"]
        cases.append((json.dumps(duplicate_use), "duplicate use_for value"))

        boolean_count = valid_notes()
        boolean_count["windows"][0]["expected_steps"] = True
        cases.append((json.dumps(boolean_count), "expected_steps must be an integer"))

        negative_count = valid_notes()
        negative_count["windows"][0]["expected_steps"] = -1
        cases.append((json.dumps(negative_count), "must be nonnegative"))

        activity_only_count = valid_notes()
        activity_only_count["windows"][2]["expected_steps"] = 12
        cases.append((json.dumps(activity_only_count), "activity-only window"))

        duplicate_label = valid_notes()
        duplicate_label["windows"][1]["label"] = duplicate_label["windows"][0]["label"]
        cases.append((json.dumps(duplicate_label), "duplicate window label"))

        duplicate_key = '{"version":1,"version":1,"windows":[]}'
        cases.append((duplicate_key, "duplicate JSON key"))

        for raw, expected in cases:
            with self.subTest(expected=expected):
                self.reset_outputs()
                self.notes.write_text(raw, encoding="utf-8")
                result = self.run_tool()
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected, result.stderr)
                self.assertFalse(self.holdout.exists())
                self.assertFalse(self.activity.exists())
                self.assertFalse(self.audit.exists())

    def test_rejects_reversed_short_overlapping_and_calibration_windows(self):
        reversed_notes = valid_notes()
        reversed_notes["windows"][0]["end"] = reversed_notes["windows"][0]["start"]

        short_notes = valid_notes()
        short_notes["windows"][0]["start"] = iso(BASE_SECOND)
        short_notes["windows"][0]["end"] = iso(BASE_SECOND + 33)

        overlapping_notes = valid_notes()
        overlapping_notes["windows"][1]["start"] = iso(BASE_SECOND + 30)

        calibration_notes = valid_notes()
        calibration_start = guided_manifest()["windows"][1]["start_ms"] // 1_000
        calibration_notes["windows"][0]["start"] = iso(calibration_start)
        calibration_notes["windows"][0]["end"] = iso(calibration_start + 40)

        cases = [
            (reversed_notes, "end must follow start"),
            (short_notes, "at least 34 seconds"),
            (overlapping_notes, "chronological and non-overlapping"),
            (calibration_notes, "overlaps guided calibration evidence"),
        ]
        for notes, expected in cases:
            with self.subTest(expected=expected):
                self.reset_outputs()
                self.write_json(self.notes, notes)
                result = self.run_tool()
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected, result.stderr)

    def test_missing_and_conflicting_crc_valid_device_seconds_fail_closed(self):
        missing_archive = self.root / "missing-archive"
        missing = required_seconds()
        missing.remove(BASE_SECOND + 20)
        write_archive(missing_archive, missing)
        result = self.run_tool(archive=missing_archive)
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing CRC-valid R10 boundary/continuity evidence", result.stderr)
        self.assertFalse(self.holdout.exists())

        ambiguous_archive = self.root / "ambiguous-archive"
        write_archive(
            ambiguous_archive,
            required_seconds(),
            ambiguous_second=BASE_SECOND + 20,
        )
        result = self.run_tool(archive=ambiguous_archive)
        self.assertEqual(result.returncode, 2)
        self.assertIn("ambiguous CRC-valid R10 frames", result.stderr)
        self.assertFalse(self.holdout.exists())

    def test_existing_output_is_refused_without_partial_publication(self):
        self.holdout.write_text("do not replace", encoding="utf-8")
        result = self.run_tool()
        self.assertEqual(result.returncode, 2)
        self.assertIn("refusing existing output", result.stderr)
        self.assertEqual(self.holdout.read_text(encoding="utf-8"), "do not replace")
        self.assertFalse(self.activity.exists())
        self.assertFalse(self.audit.exists())


if __name__ == "__main__":
    unittest.main()
