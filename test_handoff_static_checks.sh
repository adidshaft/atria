#!/usr/bin/env bash
set -euo pipefail

python3 -m py_compile test_handoff_static_checks.py
python3 test_handoff_static_checks.py

echo "test_handoff_static_checks.sh: pass"
