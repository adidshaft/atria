#!/usr/bin/env python3
"""Create, bind, and verify physical-build provenance for Atria installs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA = "atria.installed-app-provenance.v1"
SHA256_RE = re.compile(r"[0-9a-f]{64}")
COMMIT_RE = re.compile(r"[0-9a-f]{40,64}")
IGNORED_COMPONENTS = {"DerivedData", "build", "xcuserdata", ".DS_Store"}


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(root: Path, *arguments: str, check: bool = True) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip() or "git command failed")
    return result.stdout


def excluded(relative: str) -> bool:
    return any(component in IGNORED_COMPONENTS for component in Path(relative).parts)


def source_state(root: Path, source_paths: list[str]) -> dict[str, object]:
    root = root.resolve()
    if not source_paths:
        raise ValueError("at least one source path is required")
    listed = git(
        root,
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        "-z",
        "--",
        *source_paths,
    )
    paths = sorted({
        item.decode("utf-8", errors="surrogateescape")
        for item in listed.split(b"\0")
        if item and not excluded(item.decode("utf-8", errors="surrogateescape"))
    })
    content_digest = hashlib.sha256()
    for relative in paths:
        encoded_path = relative.encode("utf-8", errors="surrogateescape")
        path = root / relative
        content_digest.update(len(encoded_path).to_bytes(8, "big"))
        content_digest.update(encoded_path)
        if path.is_symlink():
            payload = os.readlink(path).encode("utf-8", errors="surrogateescape")
            marker = b"symlink\0"
        elif path.is_file():
            payload = path.read_bytes()
            marker = b"executable\0" if os.access(path, os.X_OK) else b"file\0"
        else:
            payload = b""
            marker = b"missing\0"
        content_digest.update(marker)
        content_digest.update(len(payload).to_bytes(8, "big"))
        content_digest.update(payload)

    dirty_status = git(
        root,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--",
        *source_paths,
    )
    dirty_digest = hashlib.sha256()
    dirty_digest.update(dirty_status)
    dirty_digest.update(content_digest.digest())
    commit = git(root, "rev-parse", "HEAD").decode().strip().lower()
    if not COMMIT_RE.fullmatch(commit):
        raise ValueError(f"invalid git commit: {commit!r}")
    return {
        "source_commit": commit,
        "source_dirty": bool(dirty_status),
        "source_fingerprint": content_digest.hexdigest(),
        "source_dirty_fingerprint": dirty_digest.hexdigest(),
        "source_file_count": len(paths),
        "source_paths": source_paths,
    }


def app_metadata(app: Path) -> dict[str, object]:
    info_path = app / "Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        raise ValueError("Info.plist has no CFBundleExecutable")
    executable = app / executable_name
    if not executable.is_file():
        raise ValueError(f"missing app executable: {executable}")
    bundle_id = info.get("CFBundleIdentifier")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if not all(isinstance(value, str) and value for value in (bundle_id, version, build)):
        raise ValueError("Info.plist is missing bundle id, version, or build")
    return {
        "bundle_id": bundle_id,
        "version": version,
        "build": build,
        "executable": executable_name,
        "binary_sha256": sha256_file(executable),
    }


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def matching_installed_app(metadata: dict[str, Any], bundle_id: str) -> tuple[dict[str, Any], str]:
    result = metadata.get("result")
    apps = result.get("apps") if isinstance(result, dict) else metadata.get("apps")
    if not isinstance(apps, list):
        raise ValueError("installed-app metadata has no apps array")
    matches = [app for app in apps if isinstance(app, dict) and app.get("bundleIdentifier") == bundle_id]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one installed {bundle_id} app, found {len(matches)}")
    device_id = result.get("deviceIdentifier", "unknown") if isinstance(result, dict) else "unknown"
    return matches[0], str(device_id)


def base_identity_hash(identity: dict[str, Any]) -> str:
    payload = dict(identity)
    payload.pop("identity_sha256", None)
    payload.pop("installed", None)
    payload.pop("installed_at", None)
    payload.pop("provenance_sha256", None)
    return sha256_bytes(canonical_bytes(payload))


def provenance_hash(identity: dict[str, Any]) -> str:
    payload = dict(identity)
    payload.pop("provenance_sha256", None)
    return sha256_bytes(canonical_bytes(payload))


def create(args: argparse.Namespace) -> int:
    identity: dict[str, Any] = {
        "schema": SCHEMA,
        "configuration": args.configuration,
        "created_at": datetime.now(timezone.utc).isoformat(),
        **app_metadata(args.app.resolve()),
        **source_state(args.source_root.resolve(), args.source_path),
    }
    identity["identity_sha256"] = base_identity_hash(identity)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(canonical_bytes(identity))
    print(f"app_build_identity={args.output}")
    print(f"app_binary_sha256={identity['binary_sha256']}")
    print(f"app_source_fingerprint={identity['source_fingerprint']}")
    print(f"app_source_dirty_fingerprint={identity['source_dirty_fingerprint']}")
    return 0


def bind_installed(args: argparse.Namespace) -> int:
    identity = load_json(args.identity)
    if identity.get("schema") != SCHEMA or identity.get("identity_sha256") != base_identity_hash(identity):
        raise ValueError("base build identity is invalid")
    app, device_id = matching_installed_app(load_json(args.installed_metadata), str(identity.get("bundle_id")))
    identity["installed"] = {
        "device_id": device_id,
        "bundle_id": app.get("bundleIdentifier"),
        "version": app.get("version"),
        "build": app.get("bundleVersion"),
        "bundle_container_path": app.get("bundleContainerPath"),
        "data_container_path": app.get("dataContainerPath"),
        "url": app.get("url"),
        "app_group_identifiers": sorted(app.get("appGroupIdentifiers") or []),
    }
    identity["installed_at"] = datetime.now(timezone.utc).isoformat()
    identity["provenance_sha256"] = provenance_hash(identity)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(canonical_bytes(identity))
    print(f"installed_app_provenance={args.output}")
    print(f"installed_app_provenance_sha256={identity['provenance_sha256']}")
    return 0


def verify_build(args: argparse.Namespace) -> int:
    blockers: list[str] = []
    try:
        identity = load_json(args.identity)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        identity = {}
        blockers.append(f"invalid_app_build_identity:{type(error).__name__}")
    if identity.get("schema") != SCHEMA:
        blockers.append("app_provenance_schema_mismatch")
    if identity and identity.get("identity_sha256") != base_identity_hash(identity):
        blockers.append("app_build_identity_hash_mismatch")
    try:
        current_source = source_state(args.source_root.resolve(), list(identity.get("source_paths") or []))
    except (OSError, RuntimeError, ValueError) as error:
        current_source = {}
        blockers.append(f"source_fingerprint_unavailable:{type(error).__name__}")
    for key in ("source_commit", "source_dirty", "source_fingerprint", "source_dirty_fingerprint", "source_file_count"):
        if current_source and identity.get(key) != current_source.get(key):
            blockers.append(f"app_provenance_{key}_mismatch")
    try:
        current_app = app_metadata(args.app.resolve())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        current_app = {}
        blockers.append(f"local_app_metadata_unavailable:{type(error).__name__}")
    for key in ("bundle_id", "version", "build", "executable", "binary_sha256"):
        if current_app and identity.get(key) != current_app.get(key):
            blockers.append(f"app_provenance_{key}_mismatch")
    status = "pass" if not blockers else "fail"
    print(f"app_build_provenance_status={status}")
    print("app_build_provenance_blockers=" + (",".join(blockers) if blockers else "none"))
    return 0 if not blockers else 1


def verify(args: argparse.Namespace) -> int:
    blockers: list[str] = []
    source_blockers: list[str] = []
    try:
        identity = load_json(args.identity)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        identity = {}
        blockers.append(f"invalid_app_provenance:{type(error).__name__}")

    if identity.get("schema") != SCHEMA:
        blockers.append("app_provenance_schema_mismatch")
    if identity and identity.get("identity_sha256") != base_identity_hash(identity):
        blockers.append("app_build_identity_hash_mismatch")
    if identity and identity.get("provenance_sha256") != provenance_hash(identity):
        blockers.append("app_provenance_hash_mismatch")
    binary_sha = identity.get("binary_sha256")
    if not isinstance(binary_sha, str) or not SHA256_RE.fullmatch(binary_sha):
        blockers.append("invalid_app_binary_sha256")

    try:
        current_source = source_state(args.source_root.resolve(), list(identity.get("source_paths") or []))
    except (OSError, RuntimeError, ValueError) as error:
        current_source = {}
        source_blockers.append(f"source_fingerprint_unavailable:{type(error).__name__}")
    for key in ("source_commit", "source_dirty", "source_fingerprint", "source_dirty_fingerprint", "source_file_count"):
        if current_source and identity.get(key) != current_source.get(key):
            source_blockers.append(f"app_provenance_{key}_mismatch")
    if not args.installed_only:
        blockers.extend(source_blockers)

    if args.app is not None:
        try:
            current_app = app_metadata(args.app.resolve())
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            current_app = {}
            blockers.append(f"local_app_metadata_unavailable:{type(error).__name__}")
        for key in ("bundle_id", "version", "build", "executable", "binary_sha256"):
            if current_app and identity.get(key) != current_app.get(key):
                blockers.append(f"app_provenance_{key}_mismatch")

    try:
        installed_app, device_id = matching_installed_app(
            load_json(args.installed_metadata), str(identity.get("bundle_id"))
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        installed_app = {}
        device_id = "unknown"
        blockers.append(f"installed_app_metadata_unavailable:{type(error).__name__}")
    installed = identity.get("installed") if isinstance(identity.get("installed"), dict) else {}
    comparisons = {
        "device_id": device_id,
        "bundle_id": installed_app.get("bundleIdentifier"),
        "version": installed_app.get("version"),
        "build": installed_app.get("bundleVersion"),
        "bundle_container_path": installed_app.get("bundleContainerPath"),
        "data_container_path": installed_app.get("dataContainerPath"),
        "url": installed_app.get("url"),
        "app_group_identifiers": sorted(installed_app.get("appGroupIdentifiers") or []),
    }
    for key, current in comparisons.items():
        if installed and installed.get(key) != current:
            blockers.append(f"installed_app_{key}_mismatch")
    if identity.get("bundle_id") != comparisons.get("bundle_id"):
        blockers.append("installed_app_bundle_id_mismatch")
    if identity.get("version") != comparisons.get("version"):
        blockers.append("installed_app_version_mismatch")
    if identity.get("build") != comparisons.get("build"):
        blockers.append("installed_app_build_mismatch")

    status = "pass" if not blockers else "fail"
    print(f"app_provenance_status={status}")
    print(f"app_provenance_file={args.identity}")
    print(f"app_provenance_sha256={identity.get('provenance_sha256', 'missing')}")
    print(f"app_binary_sha256={binary_sha or 'missing'}")
    print(f"app_build={identity.get('build', 'missing')}")
    print(f"app_version={identity.get('version', 'missing')}")
    print(f"app_source_commit={identity.get('source_commit', 'missing')}")
    print(f"app_source_dirty={1 if identity.get('source_dirty') else 0}")
    print(f"app_source_fingerprint={identity.get('source_fingerprint', 'missing')}")
    print(f"app_source_dirty_fingerprint={identity.get('source_dirty_fingerprint', 'missing')}")
    print(f"app_source_match_status={'pass' if not source_blockers else 'drift'}")
    print("app_source_match_blockers=" + (",".join(source_blockers) if source_blockers else "none"))
    print(f"app_provenance_verification_mode={'installed_only' if args.installed_only else 'source_and_installed'}")
    print("app_provenance_blockers=" + (",".join(blockers) if blockers else "none"))
    return 0 if not blockers else 1


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)

    create_parser = commands.add_parser("create")
    create_parser.add_argument("--app", required=True, type=Path)
    create_parser.add_argument("--source-root", required=True, type=Path)
    create_parser.add_argument("--source-path", action="append", required=True)
    create_parser.add_argument("--configuration", required=True)
    create_parser.add_argument("--output", required=True, type=Path)
    create_parser.set_defaults(function=create)

    bind_parser = commands.add_parser("bind-installed")
    bind_parser.add_argument("--identity", required=True, type=Path)
    bind_parser.add_argument("--installed-metadata", required=True, type=Path)
    bind_parser.add_argument("--output", required=True, type=Path)
    bind_parser.set_defaults(function=bind_installed)

    verify_build_parser = commands.add_parser("verify-build")
    verify_build_parser.add_argument("--identity", required=True, type=Path)
    verify_build_parser.add_argument("--source-root", required=True, type=Path)
    verify_build_parser.add_argument("--app", required=True, type=Path)
    verify_build_parser.set_defaults(function=verify_build)

    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--identity", required=True, type=Path)
    verify_parser.add_argument("--installed-metadata", required=True, type=Path)
    verify_parser.add_argument("--source-root", required=True, type=Path)
    verify_parser.add_argument("--app", type=Path)
    verify_parser.add_argument(
        "--installed-only",
        action="store_true",
        help="verify the bound installed app while reporting later source drift separately",
    )
    verify_parser.set_defaults(function=verify)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        return args.function(args)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        print(f"app_provenance_error={type(error).__name__}:{error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
