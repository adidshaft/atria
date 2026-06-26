#!/usr/bin/env python3
"""Stage 1b: residual cleanups after the bulk rename.
A) whoop3 -> strap3 (missed model enum case)
B) UserDefaults keys "whoop. -> "atria. (operational/diagnostic state only; user data is already atria.*)
C) HealthKitExporter param/tuple/var label 'whoop' -> 'strap' (strap-vs-reference comparison)
D) line "case .strapMG: return \"WHOOP MG\"" label -> "Strap MG" (NOT the device-match arg)
Preserves: whoop://, contains("WHOOP"...) device-match, model-detection match args."""
import pathlib, re

ROOT = pathlib.Path("/Users/amanpandey/projects/atria/WhoopApp")

for f in ROOT.rglob("*.swift"):
    text = f.read_text()
    orig = text
    # A) missed model case
    text = text.replace("whoop3", "strap3")
    # B) operational storage keys
    text = text.replace('"whoop.', '"atria.')
    # C) HealthKitExporter strap-vs-reference comparison labels
    if f.name == "HealthKitExporter.swift":
        text = re.sub(r"\bwhoop\b", "strap", text)
    # D) WHOOP MG model label (return value), only after a strapMG case
    text = text.replace('case .strapMG: return "WHOOP MG"', 'case .strapMG: return "Strap MG"')
    if text != orig:
        f.write_text(text)
        print("updated", f.name)
