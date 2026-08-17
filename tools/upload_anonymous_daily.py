#!/usr/bin/env python3
"""Put or head an anonymous daily research bundle on the Atria AWS bucket.

The iOS app is local-first and never opens a network client. This CLI is the
upload entry: it shells to `aws s3 cp` / `aws s3api head-object` with a
structured key that carries only a pseudonym prefix and a civil day.

    anonymous/<pseudonym-prefix8>/<YYYY-MM-DD>.json.gz
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Sequence


DEFAULT_BUCKET = "atria-anonymous-research-477817968459"
BUCKET_ENV = "ATRIA_ANONYMOUS_RESEARCH_BUCKET"
OBJECT_PREFIX = "anonymous"
PSEUDONYM_PREFIX_RE = re.compile(r"^[A-Za-z0-9]{1,8}$")
CIVIL_DAY_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
BUNDLE_NAME_RE = re.compile(
    r"^atria-research-([A-Za-z0-9]{1,8})-day\d+\.json(?:\.gz)?$"
)
OUTBOX_NAME_RE = re.compile(
    r"^atria-research-([0-9]{4}-[0-9]{2}-[0-9]{2})-[0-9a-fA-F]+\.json(?:\.gz)?$"
)

Runner = Callable[..., subprocess.CompletedProcess[str]]


class UploadError(ValueError):
    pass


def default_bucket() -> str:
    configured = os.environ.get(BUCKET_ENV, "").strip()
    return configured or DEFAULT_BUCKET


def sanitize_pseudonym_prefix(value: str) -> str:
    prefix = value.strip()
    if not PSEUDONYM_PREFIX_RE.fullmatch(prefix):
        raise UploadError(
            "pseudonym prefix must be 1–8 alphanumeric characters with no name, email, or device id"
        )
    return prefix


def sanitize_civil_day(value: str) -> str:
    day = value.strip()
    if not CIVIL_DAY_RE.fullmatch(day):
        raise UploadError("civil day must be YYYY-MM-DD")
    return day


def structured_object_key(pseudonym_prefix: str, civil_day: str) -> str:
    return f"{OBJECT_PREFIX}/{sanitize_pseudonym_prefix(pseudonym_prefix)}/{sanitize_civil_day(civil_day)}.json.gz"


def put_argv(local_path: Path, bucket: str, key: str) -> list[str]:
    return ["aws", "s3", "cp", str(local_path), f"s3://{bucket}/{key}"]


def head_argv(bucket: str, key: str) -> list[str]:
    return ["aws", "s3api", "head-object", "--bucket", bucket, "--key", key]


def run_aws(argv: Sequence[str], runner: Runner) -> subprocess.CompletedProcess[str]:
    return runner(list(argv), capture_output=True, text=True)


def infer_pseudonym_prefix(path: Path, explicit: str | None) -> str:
    if explicit:
        return sanitize_pseudonym_prefix(explicit)
    match = BUNDLE_NAME_RE.fullmatch(path.name)
    if match:
        return match.group(1)
    from_bundle = _bundle_pseudonym_prefix(path)
    if from_bundle:
        return from_bundle
    raise UploadError("pass --pseudonym-prefix or use an atria-research-<prefix>-dayN filename")


def infer_civil_day(path: Path, explicit: str | None) -> str:
    if explicit:
        return sanitize_civil_day(explicit)
    match = OUTBOX_NAME_RE.fullmatch(path.name)
    if match:
        return match.group(1)
    raise UploadError("pass --civil-day (the bundle itself has no absolute calendar date)")


def _bundle_pseudonym_prefix(path: Path) -> str | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if path.suffix == ".gz" or raw[:2] == b"\x1f\x8b":
        try:
            raw = gzip.decompress(raw)
        except OSError:
            return None
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    manifest = payload.get("manifest")
    if not isinstance(manifest, dict):
        return None
    pseudonym = manifest.get("pseudonym")
    if not isinstance(pseudonym, str) or len(pseudonym) < 8:
        return None
    try:
        return sanitize_pseudonym_prefix(pseudonym[:8])
    except UploadError:
        return None


def put_object(
    local_path: Path,
    bucket: str,
    key: str,
    runner: Runner = subprocess.run,
) -> subprocess.CompletedProcess[str]:
    if not local_path.is_file():
        raise UploadError(f"local file does not exist: {local_path}")
    size = local_path.stat().st_size
    if size <= 0:
        raise UploadError("refusing to upload an empty anonymous daily file")
    return run_aws(put_argv(local_path, bucket, key), runner)


def head_object(
    bucket: str,
    key: str,
    runner: Runner = subprocess.run,
) -> subprocess.CompletedProcess[str]:
    return run_aws(head_argv(bucket, key), runner)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    put = sub.add_parser("put", help="aws s3 cp the anonymous daily file")
    put.add_argument("--file", required=True, type=Path)
    _add_common(put)

    head = sub.add_parser("head", help="aws s3api head-object the structured key")
    head.add_argument("--file", type=Path)
    _add_common(head)
    return parser


def _add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bucket")
    parser.add_argument("--pseudonym-prefix")
    parser.add_argument("--civil-day")
    parser.add_argument("--key")


def resolve_target(args: argparse.Namespace) -> tuple[str, str]:
    bucket = (args.bucket or default_bucket()).strip()
    if not bucket:
        raise UploadError("bucket is empty")
    if args.key:
        key = str(args.key).lstrip("/")
        if not key.startswith(f"{OBJECT_PREFIX}/") or ".." in key:
            raise UploadError("explicit key must stay under the anonymous/ prefix")
        return bucket, key
    if args.file is None:
        raise UploadError("head without --key needs --file plus prefix/day, or pass --key")
    prefix = infer_pseudonym_prefix(args.file, args.pseudonym_prefix)
    day = infer_civil_day(args.file, args.civil_day)
    return bucket, structured_object_key(prefix, day)


def _print_process(command: Sequence[str], result: subprocess.CompletedProcess[str]) -> None:
    print(f"command={' '.join(command)}")
    print(f"exit={result.returncode}")
    if result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
    if result.stderr:
        print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", file=sys.stderr)


def main(argv: Sequence[str] | None = None, runner: Runner = subprocess.run) -> int:
    args = build_parser().parse_args(argv)
    try:
        bucket, key = resolve_target(args)
        if args.command == "put":
            result = put_object(args.file, bucket, key, runner=runner)
            command = put_argv(args.file, bucket, key)
        else:
            result = head_object(bucket, key, runner=runner)
            command = head_argv(bucket, key)
    except UploadError as exc:
        print(f"UPLOAD_REJECTED: {exc}", file=sys.stderr)
        return 2
    _print_process(command, result)
    print(f"bucket={bucket}")
    print(f"key={key}")
    if args.command == "put" and args.file is not None:
        print(f"local_bytes={args.file.stat().st_size}")
    return 0 if result.returncode == 0 else result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
