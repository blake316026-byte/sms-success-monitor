#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
APP_PATH="${1:-}"

if rg -n \
  'SecItem|kSec[A-Z]|LAContext|import (Security|LocalAuthentication)|linkedFramework\("(Security|LocalAuthentication)"\)|com\.local\.sms-success-monitor\.credentials' \
  "${ROOT_DIR}/Package.swift" "${ROOT_DIR}/Sources/SMSMonitorApp"; then
  echo "macOS app still contains a legacy Keychain reference" >&2
  exit 1
fi

if [[ -n "${APP_PATH}" ]]; then
  BINARY_PATH="${APP_PATH}/Contents/MacOS/SMSMonitorApp"
  if strings "${BINARY_PATH}" | grep -Fq 'com.local.sms-success-monitor.credentials'; then
    echo "macOS app binary still contains the legacy Keychain service" >&2
    exit 1
  fi
  if nm -u "${BINARY_PATH}" 2>/dev/null | grep -Eq 'SecItem|LAContext'; then
    echo "macOS app binary still references Keychain APIs" >&2
    exit 1
  fi
fi

echo "PASS: macOS app contains no legacy Keychain access"
