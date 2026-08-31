#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sms-tiancheng-login.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc "${ROOT_DIR}/scripts/TianchengLoginWebKitCheck.swift" -parse-as-library -o "${TEST_DIR}/check"
"${TEST_DIR}/check" "${ROOT_DIR}/clients/shared/auto-login/tiancheng-login.js"
