#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PLIST="${SCRIPT_DIR:h}/Resources/Info.plist"

[[ "$(plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoadsInWebContent raw "${PLIST}")" == "true" ]]

if plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw "${PLIST}" >/dev/null 2>&1; then
  echo "FAIL: native app transport security must remain enabled" >&2
  exit 1
fi

echo "PASS: HTTP is enabled only inside platform WebViews"
