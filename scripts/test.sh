#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

"${SCRIPT_DIR}/check-no-macos-keychain.sh"
"${SCRIPT_DIR}/check-macos-login-trigger.sh"
"${SCRIPT_DIR}/check-browser-cache-download.sh"
"${SCRIPT_DIR}/check-web-content-http.sh"
swift run --package-path "${ROOT_DIR}" SMSMonitorCoreChecks
node "${ROOT_DIR}/scripts/check-scan-script.mjs"
node "${ROOT_DIR}/scripts/check-finance-script.mjs"
node "${ROOT_DIR}/scripts/check-account-isolation.mjs"
node "${ROOT_DIR}/scripts/check-session-lifecycle.mjs"
zsh "${ROOT_DIR}/scripts/check-session-webkit.sh"
zsh "${ROOT_DIR}/scripts/check-table-refresh.sh"
zsh "${ROOT_DIR}/scripts/check-tiancheng-login.sh"
node "${ROOT_DIR}/scripts/check-tiancheng-routing.mjs"
node "${ROOT_DIR}/scripts/check-disabled-auto-login-routing.mjs"
node "${ROOT_DIR}/scripts/check-workspace-loading.mjs"
node "${ROOT_DIR}/scripts/check-financial-recovery.mjs"
node "${ROOT_DIR}/scripts/check-shared-finance.mjs"
node "${ROOT_DIR}/scripts/check-login-page.mjs"
node "${ROOT_DIR}/clients/shared/test-shared.mjs"

if [[ -d "${ROOT_DIR}/clients/windows-electron/node_modules" ]]; then
  npm --prefix "${ROOT_DIR}/clients/windows-electron" test
fi
