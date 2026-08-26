#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
MAC_WORKSPACE="${ROOT_DIR}/Sources/SMSMonitorApp/PlatformWorkspaceController.swift"
MAC_MONITOR="${ROOT_DIR}/Sources/SMSMonitorApp/MonitorController.swift"
WINDOWS_MAIN="${ROOT_DIR}/clients/windows-electron/src/main.mjs"
WINDOWS_PRELOAD="${ROOT_DIR}/clients/windows-electron/src/preload.cjs"
WINDOWS_UI="${ROOT_DIR}/clients/windows-electron/src/ui/workbench.html"

python3 - "$MAC_WORKSPACE" "$MAC_MONITOR" "$WINDOWS_MAIN" "$WINDOWS_PRELOAD" "$WINDOWS_UI" <<'PY'
from pathlib import Path
import sys

mac_workspace, mac_monitor, windows_main, windows_preload, windows_ui = [
    Path(path).read_text() for path in sys.argv[1:]
]

required_mac = [
    "WKWebsiteDataTypeDiskCache",
    "WKWebsiteDataTypeMemoryCache",
    "WKWebsiteDataTypeServiceWorkerRegistrations",
    "reloadFromOrigin()",
    "PlatformDownloadCoordinator.shared.attach(download)",
    "isAttachmentResponse(navigationResponse)",
    "activateFileViewerSelecting([destination])",
]
if any(fragment not in mac_workspace + mac_monitor for fragment in required_mac):
    raise SystemExit("FAIL: macOS cache clearing or download handling is incomplete")

for forbidden in ["WKWebsiteDataTypeCookies", "WKWebsiteDataTypeLocalStorage"]:
    if forbidden in mac_workspace:
        raise SystemExit(f"FAIL: macOS cache action must preserve login storage: {forbidden}")

required_windows = [
    "targetSession.on('will-download'",
    "item.setSavePath(destination)",
    "shell.showItemInFolder(destination)",
    "targetSession.clearCache()",
    "targetSession.clearCodeCaches({})",
    "'serviceworkers'",
    "'cachestorage'",
]
if any(fragment not in windows_main for fragment in required_windows):
    raise SystemExit("FAIL: Windows cache clearing or download handling is incomplete")

cache_handler = windows_main.split("ipcMain.handle('browser:clear-cache'", 1)[1].split("ipcMain.handle(", 1)[0]
for forbidden in ["'cookies'", "'localstorage'", "'indexdb'"]:
    if forbidden in cache_handler:
        raise SystemExit(f"FAIL: Windows cache action must preserve login storage: {forbidden}")

if "clearBrowserCache" not in windows_preload or 'id="clear-cache"' not in windows_ui:
    raise SystemExit("FAIL: Windows cache action is not exposed in the workbench")

print("PASS: browser cache clearing preserves login data and downloads are saved locally")
PY
