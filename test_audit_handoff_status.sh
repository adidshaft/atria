#!/usr/bin/env bash
set -euo pipefail

python3 -m py_compile tools/audit_handoff_status.py test_audit_handoff_status.py
python3 test_audit_handoff_status.py

echo "test_audit_handoff_status.sh: pass"
