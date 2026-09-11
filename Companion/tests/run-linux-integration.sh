#!/bin/bash
set -euo pipefail
export NO_AT_BRIDGE=0
export GTK_MODULES=atk-bridge
openbox >/tmp/openbox.log 2>&1 &
trap 'kill "$!" 2>/dev/null || true' EXIT
python tests/gtk_editor.py >/tmp/editor.log 2>&1 &
python -m pytest -q tests/test_protocol.py tests/test_linux_integration.py
