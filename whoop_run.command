#!/bin/zsh
cd "${0:a:h}"
SCRIPT="$(cat which_script.txt 2>/dev/null || echo scan.py)"
echo "Running $SCRIPT  ($(date))" > whoop_log.txt
.venv/bin/python "$SCRIPT" 2>&1 | tee -a whoop_log.txt
echo "---DONE exit=${pipestatus[1]}---" >> whoop_log.txt
