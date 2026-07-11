#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CLIENT_DIR="${ROOT_DIR}/clients/android"
OUTPUT_DIR="${ROOT_DIR}/dist/android"
OUTPUT_PATH="${OUTPUT_DIR}/SMS-Success-Monitor-Android.apk"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}"

"${CLIENT_DIR}/gradlew" --project-dir "${CLIENT_DIR}" :app:lintDebug :app:assembleDebug
mkdir -p "${OUTPUT_DIR}"
cp "${CLIENT_DIR}/app/build/outputs/apk/debug/app-debug.apk" "${OUTPUT_PATH}"
echo "${OUTPUT_PATH}"
