#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sms-alert-check.XXXXXX")"
trap 'rm -rf "${CHECK_DIR}"' EXIT
swiftc "${ROOT_DIR}/Sources/SMSMonitorApp/PendingOrderAlertCore.swift" \
  "${ROOT_DIR}/Sources/SMSMonitorApp/PendingOrderTiming.swift" \
  "${ROOT_DIR}/Sources/SMSMonitorApp/PendingOrdersScript.swift" \
  "${ROOT_DIR}/Sources/SMSMonitorApp/PendingOrderAlertService.swift" \
  "${ROOT_DIR}/Sources/SMSMonitorApp/PendingOrderAlertWindowController.swift" \
  "${ROOT_DIR}/scripts/PendingOrderAlertsCheck.swift" -o "${CHECK_DIR}/alerts-check"
"${CHECK_DIR}/alerts-check"
if [[ -f "${ROOT_DIR}/clients/windows-electron/src/pending-order-alerts.test.mjs" ]]; then
  node "${ROOT_DIR}/clients/windows-electron/src/pending-order-alerts.test.mjs"
fi
