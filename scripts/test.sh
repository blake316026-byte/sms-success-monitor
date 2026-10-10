#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
"${SCRIPT_DIR}/check-no-macos-keychain.sh"
"${SCRIPT_DIR}/check-browser-cache-download.sh"
"${SCRIPT_DIR}/check-web-content-http.sh"
swift run --package-path "${ROOT_DIR}" SMSMonitorCoreChecks
node "${SCRIPT_DIR}/check-public-edition.mjs"
node "${SCRIPT_DIR}/check-pending-orders.mjs"
node "${SCRIPT_DIR}/check-withdrawal-reviewers.mjs"
node "${SCRIPT_DIR}/check-workspace-loading.mjs"
node "${SCRIPT_DIR}/check-tab-reordering.mjs"
node "${SCRIPT_DIR}/check-account-isolation.mjs"
node "${SCRIPT_DIR}/check-api-auth-validation.mjs"
node "${SCRIPT_DIR}/check-login-completion.mjs"
node "${SCRIPT_DIR}/check-session-lifecycle.mjs"
node "${SCRIPT_DIR}/check-authenticated-page-recovery.mjs"
zsh "${SCRIPT_DIR}/check-session-webkit.sh"
zsh "${SCRIPT_DIR}/check-tiancheng-login.sh"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sms-public-check.XXXXXX")"
trap 'rm -rf "${CHECK_DIR}"' EXIT
swiftc "${ROOT_DIR}/Sources/SMSMonitorApp/PendingOrdersScript.swift" \
  "${ROOT_DIR}/Sources/SMSMonitorApp/PendingOrderNavigationScript.swift" \
  "${SCRIPT_DIR}/PendingOrdersWebKitCheck.swift" -o "${CHECK_DIR}/orders-check"
"${CHECK_DIR}/orders-check"
node "${ROOT_DIR}/clients/shared/test-shared.mjs"
npm --prefix "${ROOT_DIR}/clients/windows-electron" test
