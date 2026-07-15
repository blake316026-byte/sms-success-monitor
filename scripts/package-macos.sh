#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
APP_PATH="$(${SCRIPT_DIR}/build-app.sh)"
OUTPUT_DIR="${ROOT_DIR}/dist/macos"
OUTPUT_PATH="${OUTPUT_DIR}/SMS-Success-Monitor-macOS-universal.zip"

"${SCRIPT_DIR}/check-no-macos-keychain.sh" "${APP_PATH}" >&2
SMS_MONITOR_LOCAL_AUTOMATION_CHECK=1 \
  "${APP_PATH}/Contents/MacOS/SMSMonitorApp" >&2

mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${OUTPUT_PATH}"
echo "${OUTPUT_PATH}"
