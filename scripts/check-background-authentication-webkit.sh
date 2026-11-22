#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
TEST_DIR=$(mktemp -d /tmp/sms-background-auth.XXXXXX)
CHECK_SOURCE="${1:-BackgroundAuthenticationWebKitCheck.swift}"
trap 'rm -rf "$TEST_DIR"' EXIT
swift build >/dev/null
# Generate an isolated executable from the real controller. Only the credential
# directory is redirected; no production login profile or website is accessed.
node --input-type=module - "$ROOT_DIR" "$TEST_DIR" "$CHECK_SOURCE" <<'JS'
import fs from 'node:fs';
const [root, temp, checkSource] = process.argv.slice(2);
fs.writeFileSync(`${temp}/MonitorController.swift`,
  fs.readFileSync(`${root}/Sources/SMSMonitorApp/MonitorController.swift`, 'utf8') + '\n' +
  fs.readFileSync(`${root}/scripts/${checkSource}`, 'utf8'));
const store = fs.readFileSync(`${root}/Sources/SMSMonitorApp/LocalCredentialStore.swift`, 'utf8');
fs.writeFileSync(`${temp}/LocalCredentialStore.swift`, store.replace(
  'base.appendingPathComponent("SMS Platform Workbench", isDirectory: true)',
  `URL(fileURLWithPath: ${JSON.stringify(temp)}, isDirectory: true)`));
JS
sources=(Sources/SMSMonitorApp/*.swift)
sources=(${sources:#*/main.swift})
sources=(${sources:#*/MonitorController.swift})
sources=(${sources:#*/LocalCredentialStore.swift})
swiftc -target "$(uname -m)-apple-macosx13.0" -I .build/debug/Modules .build/debug/SMSMonitorCore.build/*.swift.o \
  "${sources[@]}" "$TEST_DIR/MonitorController.swift" "$TEST_DIR/LocalCredentialStore.swift" \
  -o "$TEST_DIR/check"
"$TEST_DIR/check"
