#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
APP_NAME="SMS Success Monitor.app"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}"
BUILD_DIR="${ROOT_DIR}/.build"

swift build --package-path "${ROOT_DIR}" -c release >&2

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/release/SMSMonitorApp" "${APP_DIR}/Contents/MacOS/SMSMonitorApp"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

codesign --force --deep --sign - "${APP_DIR}" >/dev/null
echo "${APP_DIR}"
