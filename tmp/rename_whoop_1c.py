#!/usr/bin/env python3
"""Stage 1c: reword USER-FACING strings that named the official WHOOP app, to a
de-branded 'official strap app'. Leaves: whoop:// , device-name match args,
factual hardware/protocol code comments, and --whoop-* launch flags (renamed later
in lockstep with the harness)."""
import pathlib

ROOT = pathlib.Path("/Users/amanpandey/projects/atria/WhoopApp")

# exact phrase replacements (user-facing strings)
PHRASES = [
    ("official WHOOP app", "official strap app"),
    ("WHOOP may be interfering", "Another app may be interfering"),
    ("WHOOP may interfere", "Another app may interfere"),
    ("uninstall or fully disable WHOOP", "uninstall or fully disable it"),
    ("uninstall WHOOP or remove its widget/background access", "uninstall the official strap app or remove its widget/background access"),
    ("disable WHOOP if readings keep dropping", "disable it if readings keep dropping"),
    ("and WHOOP isn't installed", "and the official strap app isn't installed"),
    ("when WHOOP isn't even installed", "when the official strap app isn't even installed"),
    # comment de-brand (over-blames WHOOP; only point at WHOOP ...)
    ("over-blames WHOOP; only point at WHOOP", "over-blames the official app; only point at it"),
    ("Whether the official WHOOP app is actually installed", "Whether the official strap app is actually installed"),
]

for f in ROOT.rglob("*.swift"):
    text = f.read_text()
    orig = text
    for old, new in PHRASES:
        text = text.replace(old, new)
    if text != orig:
        f.write_text(text)
        print("updated", f.name)
