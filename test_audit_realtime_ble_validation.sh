#!/usr/bin/env bash
set -euo pipefail

python3 -m py_compile tools/audit_realtime_ble_validation.py test_audit_realtime_ble_validation.py
python3 test_audit_realtime_ble_validation.py

echo "test_audit_realtime_ble_validation.sh: pass"
