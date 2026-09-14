#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sms-memory-webkit.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc \
  -parse-as-library \
  "${ROOT_DIR}/scripts/MemoryCompactionWebKitCheck.swift" \
  -o "${TEST_DIR}/check"
"${TEST_DIR}/check"
