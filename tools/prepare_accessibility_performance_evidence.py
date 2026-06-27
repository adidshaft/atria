#!/usr/bin/env python3
"""Create a measured-evidence draft for the Atria accessibility/performance audit."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
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

DEFAULT_DRAFT = Path("docs/evidence/accessibility-performance/summary.draft.json")
DEFAULT_FINAL = Path("docs/evidence/accessibility-performance/summary.json")
DEFAULT_TRACE = Path("docs/evidence/accessibility-performance/trace.trace")
MIN_SCROLL_FPS = 58.0


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
    project_plist = repo / "Atria" / "Info.plist"
    display_name = "Atria"
    version = ""
    build = ""
    if not project_plist.exists():
        return project_build_string(repo, display_name)
    try:
        with project_plist.open("rb") as handle:
            data = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return project_build_string(repo, display_name)
    display_name = str(data.get("CFBundleDisplayName") or data.get("CFBundleName") or display_name)
    version = str(data.get("CFBundleShortVersionString") or "")
    build = str(data.get("CFBundleVersion") or "")
    if not version or not build:
        return project_build_string(repo, display_name)
    return f"{display_name} {version} ({build})"


def project_build_string(repo: Path, display_name: str) -> str:
    settings = project_build_settings(repo)
    version = settings.get("MARKETING_VERSION", "unknown")
    build = settings.get("CURRENT_PROJECT_VERSION", "unknown")
    return f"{display_name} {version} ({build})"


def project_build_settings(repo: Path) -> dict[str, str]:
    project = repo / "Atria" / "Atria.xcodeproj" / "project.pbxproj"
    if not project.exists():
        return {}
    text = project.read_text(encoding="utf-8", errors="replace")
    settings: dict[str, str] = {}
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        match = re.search(rf"\b{key}\s*=\s*([^;]+);", text)
        if match:
            settings[key] = match.group(1).strip().strip('"')
    return settings


def default_manifest(repo: Path, measured_at: str) -> dict[str, object]:
    return {
        "device": "iPhone 15 Pro",
        "accessibility_checks": {check: False for check in REQUIRED_CHECKS},
        "dashboard_scroll_fps": 0,
        "instruments_trace": str(DEFAULT_TRACE),
        "measured_at": measured_at,
        "app_commit": current_git_commit(repo),
        "app_build": read_build_string(repo),
        "notes": (
            "Draft created for a physical-device accessibility/performance pass. "
            "Keep check values false and dashboard_scroll_fps at 0 until measured on iPhone 15 Pro."
        ),
    }


def apply_app_commit(manifest: dict[str, object], app_commit: str | None) -> dict[str, object]:
    if not app_commit:
        return manifest
    updated = dict(manifest)
    updated["app_commit"] = app_commit.strip()
    return updated


def repo_relative_path(repo: Path, path: Path) -> str:
    resolved = path if path.is_absolute() else repo / path
    try:
        return str(resolved.resolve().relative_to(repo.resolve()))
    except ValueError:
        return str(resolved)


def apply_measured_inputs(
    manifest: dict[str, object],
    repo: Path,
    *,
    dashboard_scroll_fps: float | None = None,
    passed_checks: list[str] | None = None,
    all_accessibility_checks_passed: bool = False,
    instruments_trace: Path | None = None,
    notes: str | None = None,
) -> dict[str, object]:
    updated = dict(manifest)
    checks = dict(updated.get("accessibility_checks", {}))
    for check in REQUIRED_CHECKS:
        checks.setdefault(check, False)
    if all_accessibility_checks_passed:
        for check in REQUIRED_CHECKS:
            checks[check] = True
    for check in passed_checks or []:
        if check not in REQUIRED_CHECKS:
            raise ValueError(f"Unknown accessibility check: {check}")
        checks[check] = True
    updated["accessibility_checks"] = {check: bool(checks.get(check)) for check in REQUIRED_CHECKS}

    if dashboard_scroll_fps is not None:
        if dashboard_scroll_fps < 0:
            raise ValueError("dashboard_scroll_fps must be non-negative")
        updated["dashboard_scroll_fps"] = dashboard_scroll_fps

    if instruments_trace is not None:
        updated["instruments_trace"] = repo_relative_path(repo, instruments_trace)

    if notes is not None:
        updated["notes"] = notes

    return updated


def manifest_blockers(repo: Path, manifest: dict[str, object]) -> list[str]:
    blockers: list[str] = []
    if manifest.get("device") != "iPhone 15 Pro":
        blockers.append("device")

    checks = manifest.get("accessibility_checks", {})
    if not isinstance(checks, dict):
        checks = {}
    for check in REQUIRED_CHECKS:
        if checks.get(check) is not True:
            blockers.append(f"accessibility_{check}")

    fps = manifest.get("dashboard_scroll_fps")
    if not isinstance(fps, (int, float)) or float(fps) < MIN_SCROLL_FPS:
        blockers.append("dashboard_scroll_fps")

    trace_value = str(manifest.get("instruments_trace", "")).strip()
    if not trace_value:
        blockers.append("instruments_trace")
    else:
        trace = Path(trace_value)
        trace_path = trace if trace.is_absolute() else repo / trace
        if not trace_path.exists():
            blockers.append("instruments_trace_file")

    for key in ("measured_at", "app_commit", "app_build"):
        if not str(manifest.get(key, "")).strip():
            blockers.append(key)

    return blockers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="Atria repo root.")
    parser.add_argument("--out", type=Path, default=DEFAULT_DRAFT, help="Output evidence draft path.")
    parser.add_argument("--measured-at", default=utc_now(), help="UTC ISO-8601 timestamp ending in Z.")
    parser.add_argument("--dashboard-scroll-fps", type=float, help="Measured dashboard scroll FPS from Release build.")
    parser.add_argument(
        "--pass-check",
        action="append",
        choices=REQUIRED_CHECKS,
        default=[],
        help="Mark one measured accessibility check as passing. Repeat for multiple checks.",
    )
    parser.add_argument(
        "--all-accessibility-checks-pass",
        action="store_true",
        help="Mark all required accessibility checks as passing after a real physical-device pass.",
    )
    parser.add_argument("--instruments-trace", type=Path, help="Path to the measured Instruments trace artifact.")
    parser.add_argument("--app-commit", help="Installed app source commit measured by the evidence pass.")
    parser.add_argument("--notes", help="Replace the manifest notes with measured-run context.")
    parser.add_argument(
        "--final",
        action="store_true",
        help="Write summary.json only if every audit field is populated with passing measured values.",
    )
    parser.add_argument("--force", action="store_true", help="Overwrite an existing draft.")
    args = parser.parse_args()

    repo = args.repo.resolve()
    output_arg = DEFAULT_FINAL if args.final and args.out == DEFAULT_DRAFT else args.out
    out = output_arg if output_arg.is_absolute() else repo / output_arg
    if out.exists() and not args.force:
        print(f"{out} already exists; pass --force to overwrite.")
        return 1
    manifest = apply_measured_inputs(
        apply_app_commit(default_manifest(repo, args.measured_at), args.app_commit),
        repo,
        dashboard_scroll_fps=args.dashboard_scroll_fps,
        passed_checks=args.pass_check,
        all_accessibility_checks_passed=args.all_accessibility_checks_pass,
        instruments_trace=args.instruments_trace,
        notes=args.notes,
    )
    if args.final:
        blockers = manifest_blockers(repo, manifest)
        if blockers:
            print("Refusing to write final accessibility/performance summary; blockers=" + ",".join(blockers))
            return 1
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"ATRIA_ACCESSIBILITY_PERFORMANCE_{'SUMMARY' if args.final else 'DRAFT'} path={out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
