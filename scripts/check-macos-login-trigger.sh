#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE="${SCRIPT_DIR:h}/Sources/SMSMonitorApp/MonitorController.swift"

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
expected = '''if url.path == "/login" {
      guard !autoLoginInProgress else { return }
      needsImmediateScan = true
      scheduleConnectionKickoff()'''

if expected not in source:
    raise SystemExit(
        "FAIL: returning to /login must re-arm the immediate scan before auto login"
    )

print("PASS: returning to /login re-arms token validation and automatic login")
PY
