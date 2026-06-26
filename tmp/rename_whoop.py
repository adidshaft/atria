#!/usr/bin/env python3
"""Stage 1 Whoop->Atria rename: Swift symbols, log tags, identifiers, enum cases,
snake-case log keys, and unambiguous user-facing labels. Preserves the functional
set (whoop:// scheme, device-name contains("WHOOP") matching, "WHOOP MG" match arg).
Exact, case-sensitive string replacements only — order matters (longest first)."""
import pathlib, sys

ROOT = pathlib.Path("/Users/amanpandey/projects/atria/WhoopApp")
files = list(ROOT.rglob("*.swift"))

# Ordered (longest / most-specific first). Exact case-sensitive replacements.
REPLACEMENTS = [
    # --- log infrastructure (the bulk) ---
    ("WHOOPDebugLog", "AtriaDebugLog"),
    ("WhoopDebugLogging", "AtriaDebugLogging"),
    ("WHOOPDBG", "ATRIADBG"),
    # --- coexistence: the OFFICIAL WHOOP APP -> "officialApp" / "OfficialApp" ---
    ("AtriaWhoopCoexistenceModal", "AtriaCoexistenceModal"),
    ("OfficialWhoopCoexistence", "OfficialAppCoexistence"),
    ("officialWhoopCoexistence", "officialAppCoexistence"),
    ("officialWhoopMayBeInstalled", "officialAppMayBeInstalled"),
    ("official_whoop_coexistence", "official_app_coexistence"),
    ("official_whoop_may_be_installed", "official_app_may_be_installed"),
    ("whoopAppInstalled", "officialAppInstalled"),
    ("whoopMayBeInstalled", "officialAppMayBeInstalled"),
    ("whoopConflictStep", "officialAppConflictStep"),
    ("whoopClearStep", "officialAppClearStep"),
    ("didRecheckWhoop", "didRecheckOfficialApp"),
    ("recheckWhoop", "recheckOfficialApp"),
    # --- core types ---
    ("WhoopBLEManager", "AtriaBLEManager"),
    ("WhoopStatusWidget", "AtriaStatusWidget"),
    ("WhoopWidget", "AtriaWidget"),     # cascades to WhoopWidgetBundle/Entry/Provider/Snapshot/...
    ("WhoopAppApp", "AtriaApp"),
    ("WhoopModel", "AtriaStrapModel"),
    ("WhoopFrame", "AtriaFrame"),
    # --- strap-hardware identifiers (whoop = the strap) ---
    ("whoopService", "strapService"),
    ("whoopStream", "strapStream"),
    ("whoopModel", "strapModel"),       # cascades to whoopModelLabel -> strapModelLabel
    ("whoopRX", "strapRX"),
    ("whoopTX", "strapTX"),
    ("whoop4Class", "strap4Class"),
    ("whoopMG", "strapMG"),             # identifier (lowercase) only; "WHOOPMG"/"WHOOP MG" untouched
    ("whoop4", "strap4"),
    ("whoop5", "strap5"),
    ("isWhoop", "isStrap"),
    # --- snake-case log field keys (strap-derived values) ---
    ("no_ready_whoop_rr_window", "no_ready_strap_rr_window"),
    ("whoop_resting_hr", "strap_resting_hr"),
    ("whoop_duration_s", "strap_duration_s"),
    ("whoop_samples", "strap_samples"),
    ("whoop_peak_hr", "strap_peak_hr"),
    ("whoop_avg_hr", "strap_avg_hr"),
    ("whoop_rmssd", "strap_rmssd"),
    ("whoop_gap_s", "strap_gap_s"),
    ("whoop_ready", "strap_ready"),
    ("whoop_kept", "strap_kept"),
    ("whoop_conf", "strap_conf"),
    ("whoop_raw", "strap_raw"),
    # --- unambiguous user-facing labels (NOT the contains("WHOOP...") match args) ---
    ('"WHOOP strap"', '"Strap"'),
    ('"WHOOP check"', '"Strap check"'),
    ("WHOOP HR/RR", "Strap HR/RR"),
    ("the WHOOP strap", "the strap"),
    ('"WHOOP 5.0"', '"Strap 5.0"'),
    ('"WHOOP 4.0"', '"Strap 4.0"'),
    ('"WHOOP 3.0"', '"Strap 3.0"'),
]

total = 0
changed_files = 0
for f in files:
    text = f.read_text()
    orig = text
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    if text != orig:
        # count net changes roughly
        f.write_text(text)
        changed_files += 1

# report residual whoop tokens (should only be preserve-set)
import subprocess
print(f"Rewrote {changed_files} files.")
