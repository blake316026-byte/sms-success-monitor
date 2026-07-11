#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
APP_NAME="SMS Success Monitor.app"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}"
ARM_BUILD_DIR="${ROOT_DIR}/.build-arm64"
X86_BUILD_DIR="${ROOT_DIR}/.build-x86_64"

swift build \
  --package-path "${ROOT_DIR}" \
  --triple arm64-apple-macosx13.0 \
  --scratch-path "${ARM_BUILD_DIR}" \
  -c release >&2
swift build \
  --package-path "${ROOT_DIR}" \
  --triple x86_64-apple-macosx13.0 \
  --scratch-path "${X86_BUILD_DIR}" \
  -c release >&2

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
lipo -create \
  "${ARM_BUILD_DIR}/arm64-apple-macosx/release/SMSMonitorApp" \
  "${X86_BUILD_DIR}/x86_64-apple-macosx/release/SMSMonitorApp" \
  -output "${APP_DIR}/Contents/MacOS/SMSMonitorApp"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

codesign --force --deep --sign - "${APP_DIR}" >/dev/null
echo "${APP_DIR}"
