#!/usr/bin/env bash
set -euo pipefail

./test_monitor_long_wear.sh
./test_handoff_static_checks.sh
./test_audit_handoff_status.sh

echo "test_handoff_local.sh: pass"
