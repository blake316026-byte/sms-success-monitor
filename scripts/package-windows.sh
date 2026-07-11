#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CLIENT_DIR="${ROOT_DIR}/clients/windows-electron"

if [[ ! -d "${CLIENT_DIR}/node_modules" ]]; then
  npm --prefix "${CLIENT_DIR}" ci
fi
npm --prefix "${CLIENT_DIR}" run package:windows
