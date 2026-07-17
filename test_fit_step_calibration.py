import json
import math
import pathlib
import struct
import subprocess
import tempfile
import unittest
import zlib


ROOT = pathlib.Path(__file__).resolve().parent


def crc8(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ 0x07) & 0xFF if value & 0x80 else (value << 1) & 0xFF
    return value


def r10_frame(device_second: int, gait: bool) -> bytes:
    payload = bytearray(1_288)
    payload[0] = 0x2B
    payload[1] = 0x0A
    struct.pack_into("<I", payload, 7, device_second)
    payload[17] = 80
    for sample in range(100):
        magnitude = 1 + (0.16 * math.sin(2 * math.pi * 2 * sample / 100) if gait else 0)
        struct.pack_into("<h", payload, 85 + sample * 2, round(magnitude * 4_096))
    declared_length = len(payload) + 4
    length = struct.pack("<H", declared_length)
    return b"\xAA" + length + bytes([crc8(length)]) + payload + struct.pack("<I", zlib.crc32(payload))


class FitStepCalibrationHoldoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.binary = pathlib.Path(cls.build.name) / "fit_step_calibration"
        subprocess.run(
            [
                "swiftc",
                "-O",
                str(ROOT / "tools/fit_step_calibration.swift"),
                str(ROOT / "Atria/Atria/AtriaR10Motion.swift"),
                str(ROOT / "Atria/Atria/FrameParser.swift"),
                "-o",
                str(cls.binary),
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self.scratch.name)
        self.archive = self.directory / "archive"
        self.archive.mkdir()
        self.base_second = 1_800_000_000
        self.training_windows = []
        self.holdout_windows = []
        rows = []
        second = self.base_second

        def add(label, kind, expected_steps, duration_seconds, gait):
            nonlocal second
            window = {
                "label": label,
                "kind": kind,
                "start_ms": second * 1_000,
                "end_ms": (second + duration_seconds) * 1_000,
                "expected_steps": expected_steps,
            }
            for timestamp in range(second, second + duration_seconds):
                rows.append(f"r10,{timestamp * 1000},0,0,0,{r10_frame(timestamp, gait).hex()}\n")
            second += duration_seconds + 1
            return window

        self.training_windows.extend(
            [
                add("Rest before", "rest", 0, 60, False),
                add("Slow 100", "walk", 100, 50, True),
                add("Normal 100", "walk", 100, 50, True),
                add("Brisk 100", "walk", 100, 50, True),
                add("Normal 200", "walk", 200, 100, True),
                add("Rest after", "rest", 0, 60, False),
            ]
        )
        self.holdout_windows.extend(
            [
                add("Independent run 100", "run", 100, 50, True),
                add("Phone handling negative", "negative", 0, 60, False),
            ]
        )
        self.rhythmic_negative_window = add(
            "Rhythmic handling negative", "negative", 0, 50, True
        )
        (self.archive / "r10.csv").write_text(
            "source,received_at_ms,a,b,c,frame_hex\n" + "".join(rows),
            encoding="utf-8",
        )
        self.training_manifest = self.write_manifest("training.json", self.training_windows)

    def tearDown(self):
        self.scratch.cleanup()

    def write_manifest(self, name, windows):
        path = self.directory / name
        path.write_text(json.dumps({"windows": windows}), encoding="utf-8")
        return path

    def run_fitter(self, holdout=None):
        command = [str(self.binary), str(self.archive), str(self.training_manifest)]
        if holdout is not None:
            command.extend(["--holdout-manifest", str(holdout)])
        return subprocess.run(command, cwd=ROOT, capture_output=True, text=True)

    @staticmethod
    def selected_line(result):
        return next(line for line in result.stdout.splitlines() if line.startswith("selected "))

    def test_legacy_cli_and_passing_holdouts_keep_the_same_selected_candidate(self):
        legacy = self.run_fitter()
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertIn("holdout_validation=not_provided", legacy.stdout)

        holdout = self.write_manifest("holdout.json", self.holdout_windows)
        validated = self.run_fitter(holdout)
        self.assertEqual(validated.returncode, 0, validated.stderr)
        self.assertEqual(self.selected_line(validated), self.selected_line(legacy))
        self.assertIn("holdout_summary windows=2 passed=2 failed=0 pass=1", validated.stdout)

    def test_bad_holdout_fails_after_the_training_candidate_is_frozen(self):
        legacy = self.run_fitter()
        bad_windows = [dict(window) for window in self.holdout_windows]
        bad_windows[0]["expected_steps"] = 110
        bad = self.run_fitter(self.write_manifest("bad-holdout.json", bad_windows))

        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertEqual(bad.returncode, 2)
        self.assertEqual(self.selected_line(bad), self.selected_line(legacy))
        self.assertIn("holdout_summary windows=2 passed=1 failed=1 pass=0", bad.stdout)
        self.assertIn("selected candidate failed independent holdout validation", bad.stderr)

    def test_missing_holdout_device_second_fails_closed(self):
        missing_second = self.holdout_windows[0]["start_ms"] // 1_000 + 10
        archive_text = (self.archive / "r10.csv").read_text(encoding="utf-8")
        filtered = [
            line
            for line in archive_text.splitlines()
            if line.startswith("source,") or int(line.split(",", 2)[1]) != missing_second * 1_000
        ]
        (self.archive / "r10.csv").write_text("\n".join(filtered) + "\n", encoding="utf-8")

        result = self.run_fitter(self.write_manifest("holdout.json", self.holdout_windows))
        self.assertEqual(result.returncode, 2)
        self.assertIn("Independent run 100", result.stdout)
        self.assertIn("breaks=1", result.stdout)
        self.assertIn("invalid motion evidence", result.stderr)

    def test_zero_step_negative_requires_exactly_zero(self):
        windows = self.holdout_windows + [self.rhythmic_negative_window]
        result = self.run_fitter(self.write_manifest("rhythmic-negative.json", windows))

        self.assertEqual(result.returncode, 2)
        self.assertRegex(result.stdout, r"false_steps=[1-9][0-9]* pass=0")
        self.assertIn("selected candidate failed independent holdout validation", result.stderr)

    def test_holdout_requires_both_counted_and_zero_step_windows(self):
        positive_only = self.run_fitter(
            self.write_manifest("positive-only.json", [self.holdout_windows[0]])
        )
        negative_only = self.run_fitter(
            self.write_manifest("negative-only.json", [self.holdout_windows[1]])
        )

        self.assertEqual(positive_only.returncode, 2)
        self.assertIn("at least one zero-step negative", positive_only.stderr)
        self.assertEqual(negative_only.returncode, 2)
        self.assertIn("at least one counted walk or run", negative_only.stderr)

    def test_overlapping_holdout_is_rejected(self):
        overlap = [dict(self.holdout_windows[0]), dict(self.holdout_windows[1])]
        overlap[0]["start_ms"] = self.training_windows[1]["start_ms"]
        overlap[0]["end_ms"] = self.training_windows[1]["end_ms"]
        result = self.run_fitter(self.write_manifest("overlap.json", overlap))
        self.assertEqual(result.returncode, 2)
        self.assertIn("holdout overlaps calibration evidence", result.stderr)


if __name__ == "__main__":
    unittest.main()
