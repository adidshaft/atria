#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


MODULE_PATH = Path(__file__).with_name("upload_anonymous_daily.py")
SPEC = importlib.util.spec_from_file_location("upload_anonymous_daily", MODULE_PATH)
assert SPEC and SPEC.loader
upload = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upload)


class RecordingRunner:
    def __init__(self, returncode: int = 0, stdout: str = "") -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.calls: list[list[str]] = []

    def __call__(self, argv, capture_output=True, text=True):  # noqa: ANN001
        self.calls.append(list(argv))
        return subprocess.CompletedProcess(argv, self.returncode, self.stdout, "")


class UploadAnonymousDailyTests(unittest.TestCase):
    def test_structured_key_is_pseudonym_prefix_and_civil_day(self) -> None:
        key = upload.structured_object_key("550e8400", "2026-08-17")
        self.assertEqual(key, "anonymous/550e8400/2026-08-17.json.gz")
        self.assertNotIn("Jane", key)
        self.assertNotIn("@", key)
        self.assertNotIn("iPhone", key)

    def test_rejects_identifying_prefix(self) -> None:
        with self.assertRaisesRegex(upload.UploadError, "alphanumeric"):
            upload.structured_object_key("Jane Doe", "2026-08-17")

    def test_put_and_head_argv_target_structured_key(self) -> None:
        path = Path("/tmp/does-not-matter.json.gz")
        key = upload.structured_object_key("aaaaaaaa", "2026-08-17")
        self.assertEqual(
            upload.put_argv(path, upload.DEFAULT_BUCKET, key),
            [
                "aws",
                "s3",
                "cp",
                str(path),
                f"s3://{upload.DEFAULT_BUCKET}/{key}",
            ],
        )
        self.assertEqual(
            upload.head_argv(upload.DEFAULT_BUCKET, key),
            [
                "aws",
                "s3api",
                "head-object",
                "--bucket",
                upload.DEFAULT_BUCKET,
                "--key",
                key,
            ],
        )

    def test_main_put_drives_aws_s3_cp_for_the_resolved_key(self) -> None:
        runner = RecordingRunner(stdout="upload: local -> s3\n")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "atria-research-aaaaaaaa-day3.json.gz"
            path.write_bytes(b"anonymous-daily-fixture\n")
            code = upload.main(
                [
                    "put",
                    "--file",
                    str(path),
                    "--civil-day",
                    "2026-08-17",
                ],
                runner=runner,
            )
        self.assertEqual(code, 0)
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(
            runner.calls[0],
            upload.put_argv(path, upload.DEFAULT_BUCKET, "anonymous/aaaaaaaa/2026-08-17.json.gz"),
        )

    def test_main_head_drives_aws_s3api_head_object(self) -> None:
        runner = RecordingRunner(stdout='{"ContentLength": 24}\n')
        code = upload.main(
            [
                "head",
                "--key",
                "anonymous/aaaaaaaa/2026-08-17.json.gz",
            ],
            runner=runner,
        )
        self.assertEqual(code, 0)
        self.assertEqual(
            runner.calls[0],
            upload.head_argv(upload.DEFAULT_BUCKET, "anonymous/aaaaaaaa/2026-08-17.json.gz"),
        )

    def test_infer_prefix_from_gzip_manifest(self) -> None:
        payload = {
            "manifest": {"pseudonym": "550e8400-e29b-41d4-a716-446655440000", "schema": 6},
            "sessions": [{"startRel": 120.0, "hrPoints": [[120.0, 60]]}],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "daily.json.gz"
            import gzip

            path.write_bytes(gzip.compress(json.dumps(payload).encode("utf-8")))
            prefix = upload.infer_pseudonym_prefix(path, None)
        self.assertEqual(prefix, "550e8400")

    def test_resolve_target_uses_shipped_default_bucket(self) -> None:
        args = SimpleNamespace(
            bucket=None,
            key=None,
            file=Path("atria-research-bbbbbbbb-day0.json.gz"),
            pseudonym_prefix=None,
            civil_day="2026-08-17",
        )
        bucket, key = upload.resolve_target(args)
        self.assertEqual(bucket, upload.DEFAULT_BUCKET)
        self.assertEqual(key, "anonymous/bbbbbbbb/2026-08-17.json.gz")


if __name__ == "__main__":
    unittest.main()
