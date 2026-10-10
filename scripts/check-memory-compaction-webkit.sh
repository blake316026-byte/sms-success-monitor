#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sms-memory-webkit.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

node --input-type=module - "$ROOT_DIR" "$TEST_DIR" <<'JS'
import fs from 'node:fs';
const [root, out] = process.argv.slice(2);
const source = fs.readFileSync(`${root}/Sources/SMSMonitorApp/MonitorController.swift`, 'utf8');
const start = source.indexOf('  private static func compactedPageBaseURL(');
const end = source.indexOf('  private func restoreCompactedPageIfNeeded()', start);
if (start < 0 || end < 0) throw new Error('Missing production memory helpers');
fs.writeFileSync(`${out}/ProductionMemoryPage.swift`, `import Foundation\nenum ProductionMemoryPage {\n${source.slice(start, end).replaceAll('private static func', 'static func')}\n}`);
JS

swiftc \
  -parse-as-library \
  "${TEST_DIR}/ProductionMemoryPage.swift" \
  "${ROOT_DIR}/scripts/MemoryCompactionWebKitCheck.swift" \
  -o "${TEST_DIR}/check"
"${TEST_DIR}/check"
