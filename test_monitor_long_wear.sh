#!/usr/bin/env bash
set -euo pipefail

python3 -m py_compile tools/monitor_long_wear.py test_monitor_long_wear.py
python3 test_monitor_long_wear.py

echo "test_monitor_long_wear.sh: pass"
