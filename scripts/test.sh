#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

swift run --package-path "${ROOT_DIR}" SMSMonitorCoreChecks
node "${ROOT_DIR}/scripts/check-scan-script.mjs"
node "${ROOT_DIR}/clients/shared/test-shared.mjs"

if [[ -d "${ROOT_DIR}/clients/windows-electron/node_modules" ]]; then
  npm --prefix "${ROOT_DIR}/clients/windows-electron" test
fi
