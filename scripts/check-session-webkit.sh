#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sms-session-webkit.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
  "${ROOT_DIR}/Sources/SMSMonitorApp/SessionLifecycleScript.swift" \
  "${ROOT_DIR}/Sources/SMSMonitorApp/ScanScript.swift" \
  "${ROOT_DIR}/Sources/SMSMonitorApp/FinanceScript.swift" \
  "${ROOT_DIR}/scripts/SessionLifecycleWebKitCheck.swift" \
  -o "${TEST_DIR}/check"
"${TEST_DIR}/check"
