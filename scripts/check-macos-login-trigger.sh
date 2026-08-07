#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE="${SCRIPT_DIR:h}/Sources/SMSMonitorApp/MonitorController.swift"

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
expected_direct = '''if let profile = credentialStore.profile(for: configuration.id), profile.canAutoLogin {
        handleAuthenticationRequired(
          "平台登录页已打开。",
          progressMessage: "正在自动登录"
        )'''
expected_fallback = '''} else {
        needsImmediateScan = true
        scheduleConnectionKickoff()
      }'''

if expected_direct not in source or expected_fallback not in source:
    raise SystemExit(
        "FAIL: /login must start configured auto login and keep token fallback for unconfigured profiles"
    )

print("PASS: /login starts configured auto login and keeps token fallback")
PY
