#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Falha na instalacao: este instalador e somente para macOS. Use install.sh para Linux." >&2
  exit 1
fi

INSTALL_URL="https://raw.githubusercontent.com/soxvip/dgsis-claude-installer/main/install.sh"
SCRIPT_DIR=""

if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "bash" ] && [ "${BASH_SOURCE[0]}" != "-" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install.sh" ]; then
  exec bash "$SCRIPT_DIR/install.sh" "$@"
fi

TMP_SCRIPT="${TMPDIR:-/tmp}/dgsis-claude-install.sh"
curl -fsSL "$INSTALL_URL" -o "$TMP_SCRIPT"
exec bash "$TMP_SCRIPT" "$@"
