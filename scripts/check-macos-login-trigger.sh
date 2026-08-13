#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE="${SCRIPT_DIR:h}/Sources/SMSMonitorApp/MonitorController.swift"

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
expected_probe = '''if url.path == "/login" {
      guard !autoLoginInProgress else { return }
      needsImmediateScan = true
      scheduleConnectionKickoff()
      return
    }'''
forbidden_direct = '''"平台登录页已打开。",
          progressMessage: "正在自动登录"'''
expected_valid_token = '''} else {
            scheduleNextScanAfterCurrentRun()
            if metrics.shouldAlert(threshold: configuration.alertThreshold)'''

if expected_probe not in source or expected_valid_token not in source or forbidden_direct in source:
    raise SystemExit(
        "FAIL: /login must validate the saved token before starting captcha auto login"
    )

print("PASS: /login validates the saved token before captcha auto login")
PY
