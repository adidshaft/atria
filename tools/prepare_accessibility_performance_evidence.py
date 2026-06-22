#!/usr/bin/env python3
"""Create a measured-evidence draft for the Atria accessibility/performance audit."""

from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
from datetime import datetime, timezone
from pathlib import Path


REQUIRED_CHECKS = [
    "reduce_transparency",
    "increase_contrast",
    "reduce_motion",
    "light_mode",
    "dark_mode",
]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def current_git_commit(repo: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return ""
    return result.stdout.strip()


def read_build_string(repo: Path) -> str:
    project_plist = repo / "WhoopApp" / "Info.plist"
    if not project_plist.exists():
        return ""
    with project_plist.open("rb") as handle:
        data = plistlib.load(handle)
    display_name = str(data.get("CFBundleDisplayName") or data.get("CFBundleName") or "Atria")
    version = str(data.get("CFBundleShortVersionString") or "unknown")
    build = str(data.get("CFBundleVersion") or "unknown")
    return f"{display_name} {version} ({build})"


def default_manifest(repo: Path, measured_at: str) -> dict[str, object]:
    return {
        "device": "iPhone 15 Pro",
        "accessibility_checks": {check: False for check in REQUIRED_CHECKS},
        "dashboard_scroll_fps": 0,
        "instruments_trace": "docs/evidence/accessibility-performance/trace.trace",
        "measured_at": measured_at,
        "app_commit": current_git_commit(repo),
        "app_build": read_build_string(repo),
        "notes": (
            "Draft created for a physical-device accessibility/performance pass. "
            "Keep check values false and dashboard_scroll_fps at 0 until measured on iPhone 15 Pro."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="Atria repo root.")
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("docs/evidence/accessibility-performance/summary.draft.json"),
        help="Output evidence draft path. The final audit only auto-discovers summary.json.",
    )
    parser.add_argument("--measured-at", default=utc_now(), help="UTC ISO-8601 timestamp ending in Z.")
    parser.add_argument("--force", action="store_true", help="Overwrite an existing draft.")
    args = parser.parse_args()

    repo = args.repo.resolve()
    out = args.out if args.out.is_absolute() else repo / args.out
    if out.exists() and not args.force:
        print(f"{out} already exists; pass --force to overwrite.")
        return 1
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(default_manifest(repo, args.measured_at), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"ATRIA_ACCESSIBILITY_PERFORMANCE_DRAFT path={out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
