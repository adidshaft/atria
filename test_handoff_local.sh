#!/usr/bin/env bash
set -euo pipefail

./test_monitor_long_wear.sh
python3 -m py_compile tools/monitor_realtime_ble.py test_monitor_realtime_ble.py
python3 test_monitor_realtime_ble.py
./test_prepare_accessibility_performance_evidence.sh
./test_handoff_static_checks.sh
./test_audit_handoff_status.sh
./test_audit_realtime_ble_validation.sh

echo "test_handoff_local.sh: pass"
