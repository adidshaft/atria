#!/bin/zsh
SCRIPT_DIR=${0:A:h}
export PYTHONPATH="$SCRIPT_DIR/.venv/lib/python3.14/site-packages"
exec "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python" "$@"
