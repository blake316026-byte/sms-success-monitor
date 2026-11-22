#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
TEST_DIR=$(mktemp -d /tmp/sms-detached-tabs.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
swift build >/dev/null
node --input-type=module - "$ROOT_DIR" "$TEST_DIR" <<'JS'
import fs from 'node:fs';
const [root,temp]=process.argv.slice(2);
fs.writeFileSync(temp+'/PlatformWorkspaceController.swift',
  fs.readFileSync(root+'/Sources/SMSMonitorApp/PlatformWorkspaceController.swift','utf8')+'\n'+
  fs.readFileSync(root+'/scripts/DetachedTabsWebKitCheck.swift','utf8'));
const store=fs.readFileSync(root+'/Sources/SMSMonitorApp/LocalCredentialStore.swift','utf8');
fs.writeFileSync(temp+'/LocalCredentialStore.swift',store.replace(
  'base.appendingPathComponent("SMS Platform Workbench", isDirectory: true)',
  'URL(fileURLWithPath: '+JSON.stringify(temp)+', isDirectory: true)'));
JS
sources=(Sources/SMSMonitorApp/*.swift)
sources=(${sources:#*/main.swift})
sources=(${sources:#*/PlatformWorkspaceController.swift})
sources=(${sources:#*/LocalCredentialStore.swift})
swiftc -target "$(uname -m)-apple-macosx13.0" -I .build/debug/Modules .build/debug/SMSMonitorCore.build/*.swift.o \
  "${sources[@]}" "$TEST_DIR/PlatformWorkspaceController.swift" "$TEST_DIR/LocalCredentialStore.swift" -o "$TEST_DIR/check"
"$TEST_DIR/check" | tee "$TEST_DIR/result"
rg -q '^PASS: detachable tabs complete$' "$TEST_DIR/result"
