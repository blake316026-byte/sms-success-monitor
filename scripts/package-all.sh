#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"

"${SCRIPT_DIR}/test.sh"
"${SCRIPT_DIR}/package-macos.sh"
"${SCRIPT_DIR}/package-windows.sh"
"${SCRIPT_DIR}/package-android.sh"
