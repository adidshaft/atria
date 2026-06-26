#!/usr/bin/env python3
"""Stage 1d: de-brand user-facing coexistence strings, technical comments, and the
strap-vs-reference comparison labels in Sessions.swift.
PRESERVE (do-no-harm / functional): on-disk data paths whoop-historical /
whoop-backups / whoop-active-session.json (orphaning would lose user backups),
the factual device-name example "Adidshaft's WHOOP", whoop:// , --whoop-* flags,
and contains("WHOOP"...) device-name matching."""
import pathlib, re

ROOT = pathlib.Path("/Users/amanpandey/projects/atria/WhoopApp")

SENTINELS = {
    "whoop-historical": "\x00P0\x00",
    "whoop-backups": "\x00P1\x00",
    "whoop-active-session": "\x00P2\x00",
    "Adidshaft's WHOOP": "\x00P3\x00",
    'contains("WHOOP': "\x00P4\x00",
    '"--whoop': "\x00P5\x00",
    "whoop://": "\x00P6\x00",
}

PHRASES = [
    # --- user-facing coexistence strings ---
    ("Remove WHOOP first", "Remove the official strap app first"),
    ("Free strap from WHOOP.", "Free strap from the official app."),
    ('"Remove WHOOP app"', '"Remove the official strap app"'),
    ("Only if WHOOP grabs the strap again", "Only if another app grabs the strap again"),
    ("If WHOOP or its widget is still running", "If the official strap app or its widget is still running"),
    ("Delete the WHOOP app", "Delete the official strap app"),
    ("Press and hold the WHOOP icon", "Press and hold the official strap app's icon"),
    ("Log out of WHOOP, then turn off", "Log out of the official strap app, then turn off"),
    ("Remove or disable WHOOP first", "Remove or disable the official strap app first"),
    ("Check WHOOP coexistence", "Check app coexistence"),
    ("when WHOOP may reclaim the strap", "when another app may reclaim the strap"),
    ("After WHOOP is removed or disabled", "After the official strap app is removed or disabled"),
    ('"WHOOP conflict"', '"App conflict"'),
    ("Remove WHOOP, then reconnect.", "Remove the official strap app, then reconnect."),
    ("Remove WHOOP if drops return.", "Remove the official strap app if drops return."),
    ('"WHOOP risk"', '"App conflict"'),
    ("Official WHOOP may reclaim BLE in the background. Close or remove WHOOP before relying on Atria.",
     "The official strap app may reclaim BLE in the background. Close or remove it before relying on Atria."),
    ("WHOOP app or widgets can interrupt strap ownership and fragment saved sessions.",
     "The official strap app or its widgets can interrupt strap ownership and fragment saved sessions."),
    ("WHOOP can reclaim the strap and fragment readings.",
     "The official strap app can reclaim the strap and fragment readings."),
    ('"WHOOP still detected."', '"Official strap app still detected."'),
    ("No competing WHOOP app detected.", "No competing app detected."),
    # --- comments ---
    ("when WHOOP interference is suspected", "when interference from the official strap app is suspected"),
    ("Step 2: WHOOP coexistence", "Step 2: app coexistence"),
    ("One decoded frame from the WHOOP proprietary stream.", "One decoded frame from the strap's proprietary stream."),
    ("the real WHOOP device frame trailer", "the real strap device frame trailer"),
    ("Wrap a payload in a valid WHOOP frame", "Wrap a payload in a valid strap frame"),
    ("no cloud, no WHOOP account", "no cloud, no manufacturer account"),
    ("received from WHOOP realtime frames", "received from strap realtime frames"),
    ("extracted from WHOOP `0x32` text", "extracted from strap `0x32` text"),
    ("decoded from WHOOP `0x33` candidate", "decoded from strap `0x33` candidate"),
    ("across the whole day, like WHOOP).", "across the whole day)."),
    ("WHOOP's core daily loop:", "The core daily loop:"),
    ("WHOOP-style headline metrics", "Industry-style headline metrics"),
    ("honest approximations of WHOOP's proprietary scores", "honest approximations of the proprietary scores"),
    ("HRV-driven recovery (WHOOP's primary signal)", "HRV-driven recovery (the primary signal)"),
    ("WHOOP exposes only a level", "The strap exposes only a level"),
    ("WHOOP straps do not populate", "These straps do not populate"),
    ("which WHOOP seeds from the owner's account", "which the strap seeds from the owner's account"),
    ("expected WHOOP/heart-rate", "expected strap/heart-rate"),
    ("only attach if this is the WHOOP (by service or name)", "only attach if this is the strap (by service or name)"),
    ("Connects to a WHOOP strap over BLE", "Connects to the strap over BLE"),
    ("// WHOOP proprietary service + characteristics", "// strap proprietary service + characteristics"),
    # --- internal command alias ---
    ('case "coexistence", "whoop": self = .coexistence', 'case "coexistence": self = .coexistence'),
]

for f in ROOT.rglob("*.swift"):
    text = f.read_text()
    orig = text
    for k, v in SENTINELS.items():
        text = text.replace(k, v)
    for old, new in PHRASES:
        text = text.replace(old, new)
    # strap-vs-reference comparison labels (Sessions only; HealthKitExporter done in 1b)
    if f.name == "Sessions.swift":
        text = re.sub(r"\bwhoop\b", "strap", text)
        text = text.replace('"whoop_\\(', '"strap_\\(')
    for k, v in SENTINELS.items():
        text = text.replace(v, k)
    if text != orig:
        f.write_text(text)
        print("updated", f.name)
