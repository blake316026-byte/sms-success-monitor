#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sms-table-refresh.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "${ROOT_DIR}/Sources/SMSMonitorApp/MonitorTableRefresh.swift" \
  "${ROOT_DIR}/scripts/TableRefreshCheck.swift" -o "${TEST_DIR}/check"
"${TEST_DIR}/check"
