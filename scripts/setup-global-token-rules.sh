#!/usr/bin/env bash
# ============================================================
#  DEPRECATED — This script is now a thin wrapper around
#  setup-token-optimizer.sh, which includes all cross-platform
#  rule syncing (OpenCode, Devin, Windsurf, Cascade).
#
#  Usage: bash setup-global-token-rules.sh [--dry-run]
#
#  For the full stack (packages + plugins + rules):
#    bash setup-token-optimizer.sh [--dry-run]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_SCRIPT="$SCRIPT_DIR/setup-token-optimizer.sh"

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: bash setup-global-token-rules.sh [--dry-run]"
      echo ""
      echo "DEPRECATED: This script now delegates to setup-token-optimizer.sh"
      echo "which installs the full stack + syncs rules to all platforms."
      echo ""
      echo "Run the canonical script instead:"
      echo "  bash $TOKEN_SCRIPT [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "[wrapper] setup-global-token-rules.sh is deprecated."
echo "[wrapper] Delegating to setup-token-optimizer.sh ..."
echo ""

if [[ "$DRY_RUN" == true ]]; then
  bash "$TOKEN_SCRIPT" --dry-run
else
  bash "$TOKEN_SCRIPT"
fi
