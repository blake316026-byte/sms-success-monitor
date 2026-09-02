#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE="${SCRIPT_DIR:h}/Sources/SMSMonitorApp/MonitorController.swift"

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
expected_auth_route = '''private func requiresInteractiveAuthentication(_ url: URL) -> Bool {
    requiresAuthentication(url)
  }'''
expected_auto_login = '''if requiresInteractiveAuthentication(currentURL) {
      handleAuthenticationRequired("平台登录已失效。")
      return
    }'''
forbidden_direct = '''"平台登录页已打开。",
          progressMessage: "正在自动登录"'''
expected_identity_recovery = '''prepareAuthenticationRecovery(from: payload)'''
expected_login_page_check = '''loginPageUsername: identity.username'''
expected_active_page_retry = '''handleAuthenticationRequired("平台需要重新登录。")'''

if (
    expected_auth_route not in source
    or expected_auto_login not in source
    or expected_identity_recovery not in source
    or expected_login_page_check not in source
    or expected_active_page_retry not in source
    or forbidden_direct in source
    or "pageSessionRecoveryAttempted" in source
    or "restoredPageSession" in source
):
    raise SystemExit(
        "FAIL: /login must validate the account and resume saved-account login after expiry, refresh or selection"
    )

print("PASS: /login always resumes the saved-account captcha flow without restoring a partial token session")
PY
