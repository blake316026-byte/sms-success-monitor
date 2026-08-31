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
expected_session_recovery = '''if !pageSessionRecoveryAttempted && (!usedFallbackToken || restoredPageSession) {'''
expected_login_fallback = '''handleAuthenticationRequired(
              "页面登录态无法通过有效 Token 恢复。",
              progressMessage: "页面会话已失效，正在自动登录"
            )'''
expected_identity_recovery = '''prepareAuthenticationRecovery(from: payload)'''
expected_login_page_check = '''loginPageUsername: identity.username'''
expected_active_page_retry = '''handleAuthenticationRequired("平台需要重新登录。")'''

if (
    expected_probe not in source
    or expected_session_recovery not in source
    or expected_login_fallback not in source
    or expected_identity_recovery not in source
    or expected_login_page_check not in source
    or expected_active_page_retry not in source
    or forbidden_direct in source
):
    raise SystemExit(
        "FAIL: /login must validate the account and resume saved-account login after expiry, refresh or selection"
    )

print("PASS: /login validates the same account and resumes captcha login after expiry, refresh or selection")
PY
