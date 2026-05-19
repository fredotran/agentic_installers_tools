#!/usr/bin/env bash
# ============================================================
#  AI Config Backup & Restore — Unified
#  Save and load configurations for Windsurf, Codeium, Devin,
#  OpenCode, Oh-My-OpenAgent, and GitHub Copilot CLI in one operation.
#
#  Usage:
#    bash backup-restore-ai-configs.sh save  [--format=dir|tar.gz] [--dest=PATH]
#    bash backup-restore-ai-configs.sh restore --from=PATH [--dry-run]
#    bash backup-restore-ai-configs.sh list   [--dest=PATH]
#
#  Examples:
#    bash backup-restore-ai-configs.sh save
#    bash backup-restore-ai-configs.sh save --format=tar.gz --dest=~/backups
#    bash backup-restore-ai-configs.sh restore --from=~/backups/ai-configs-20260519_120000
#    bash backup-restore-ai-configs.sh list
# ============================================================

set -euo pipefail

# ─── Colors ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
info() { echo -e "${CYAN}→ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
step() { echo -e "\n${BOLD}${BLUE}══ $* ${RESET}"; }
dry()  { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }

# ─── Defaults ───────────────────────────────────────────────
ACTION=""
FORMAT="dir"
DEST="${AI_CONFIG_BACKUP_DIR:-$HOME/backups/ai-configs}"
FROM=""
DRY_RUN=false
AUTO_CONFIRM=false

# ─── Temp dir tracking for cleanup ──────────────────────────
STAGE=""
PREVIEW_DIR=""

cleanup() {
  [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf "$STAGE"
  [[ -n "$PREVIEW_DIR" && -d "$PREVIEW_DIR" ]] && rm -rf "$PREVIEW_DIR"
  return 0
}
trap cleanup EXIT

# ─── Parse args ─────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    save|restore|list) ACTION="$1"; shift ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    --dest=*) DEST="${1#*=}"; shift ;;
    --from=*) FROM="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) AUTO_CONFIRM=true; shift ;;
    -h|--help)
      cat << 'HELP'
Usage: bash backup-restore-ai-configs.sh <command> [options]

Commands:
  save    Archive all AI tool configs
  restore Restore configs from a backup
  list    Show available backups

Options:
  --format=dir|tar.gz   Output format for save (default: dir)
  --dest=PATH           Where to store backups (default: ~/backups/ai-configs)
  --from=PATH           Backup to restore from (required for restore)
  --dry-run             Show what would happen without doing it
  --yes                 Auto-confirm restore without interactive prompt

Examples:
  bash backup-restore-ai-configs.sh save
  bash backup-restore-ai-configs.sh save --format=tar.gz --dest=/mnt/backup
  bash backup-restore-ai-configs.sh restore --from=~/backups/ai-configs/ai-configs-20260519_120000
  bash backup-restore-ai-configs.sh list
HELP
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  echo "No command given. Use: save | restore | list" >&2
  exit 1
fi

# Resolve tilde in paths
DEST="${DEST/#\~/$HOME}"
FROM="${FROM/#\~/$HOME}"

# ─── Config definitions ─────────────────────────────────────
declare -A CONFIG_DIRS
declare -A CONFIG_FILES

# Windsurf
CONFIG_DIRS[windsurf]="$HOME/.codeium/windsurf/skills $HOME/.codeium/.windsurf/workflows"
CONFIG_FILES[windsurf]="$HOME/.codeium/windsurf/memories/global_rules.md $HOME/.codeium/windsurf/onboarding.json"

# Codeium (shared root-level rules)
CONFIG_FILES[codeium]="$HOME/.codeium/memories/global_rules.md"

# Devin
CONFIG_DIRS[devin]="$HOME/.config/devin/skills $HOME/.config/devin/cli"
CONFIG_FILES[devin]="$HOME/.config/devin/config.json $HOME/.devin/config.local.json $HOME/.config/devin/model_list"

# OpenCode
CONFIG_DIRS[opencode]="$HOME/.config/opencode/plugin $HOME/.config/opencode/skills $HOME/.config/opencode/templates $HOME/.config/opencode/commands $HOME/.config/opencode/agent $HOME/.config/opencode/command $HOME/.config/opencode/node_modules $HOME/.config/opencode/plugins $HOME/.config/opencode/plugin-data $HOME/.config/opencode/installed-plugins"
CONFIG_FILES[opencode]="$HOME/.config/opencode/AGENTS.md $HOME/.config/opencode/opencode.jsonc $HOME/.config/opencode/opencode.json $HOME/.config/opencode/oh-my-openagent.json $HOME/.config/opencode/dcp.jsonc $HOME/.config/opencode/package.json $HOME/.config/opencode/package-lock.json $HOME/.config/opencode/.mcp.json $HOME/.config/opencode/config.json $HOME/.config/opencode/settings.json $HOME/.config/opencode/.gitignore"

# Oh My OpenAgent / OpenDevin (local plugin path may be referenced in opencode.json)
CONFIG_DIRS[ohmyopendevin]="$HOME/Code/oh-my-opendevin"

# Oh My OpenAgent (same file as opencode oh-my-openagent.json)
# intentionally merged into opencode above

# GitHub Copilot CLI
CONFIG_DIRS[copilot]="$HOME/.copilot"

# Shared helpers
CONFIG_FILES[helpers]="$HOME/.local/bin/devin-note"

# ─── Helper: count items ────────────────────────────────────
count_items() {
  local tool="$1"
  local n=0
  # dirs
  if [[ -n "${CONFIG_DIRS[$tool]:-}" ]]; then
    for d in ${CONFIG_DIRS[$tool]}; do
      if [[ -d "$d" ]]; then
        n=$((n + $(find "$d" -type f 2>/dev/null | wc -l)))
      fi
    done
  fi
  # files
  if [[ -n "${CONFIG_FILES[$tool]:-}" ]]; then
    for f in ${CONFIG_FILES[$tool]}; do
      if [[ -f "$f" ]]; then
        n=$((n + 1))
      fi
    done
  fi
  echo "$n"
}

# ─── Helper: copy with mkdir and dry-run awareness ────────
smart_copy() {
  local src="$1"
  local dst="$2"
  if [[ "$DRY_RUN" == true ]]; then
    if [[ -d "$src" ]]; then
      dry "Would copy dir  $src → $dst"
    else
      dry "Would copy file $src → $dst"
    fi
    return
  fi
  if [[ -d "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -rp "$src" "$dst"
  elif [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
  fi
}

# ─── Helper: backup existing file before overwrite ─────────
backup_target() {
  local target="$1"
  if [[ "$DRY_RUN" == true ]]; then
    if [[ -e "$target" ]]; then
      dry "Would back up existing $target before overwrite"
    fi
    return
  fi
  if [[ -e "$target" ]]; then
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    cp -rp "$target" "${target}.backup.${ts}"
    info "Backed up existing: ${target}.backup.${ts}"
  fi
}

# ─── SAVE ───────────────────────────────────────────────────
if [[ "$ACTION" == "save" ]]; then
  TS=$(date +%Y%m%d_%H%M%S)
  BASENAME="ai-configs-${TS}"

  if [[ "$FORMAT" == "tar.gz" ]]; then
    OUT_PATH="${DEST}/${BASENAME}.tar.gz"
  else
    OUT_PATH="${DEST}/${BASENAME}"
  fi

  step "Save — collecting AI tool configurations"
  info "Destination: $OUT_PATH"
  info "Format: $FORMAT"

  if [[ "$DRY_RUN" == true ]]; then
    dry "Would create $OUT_PATH"
  else
    mkdir -p "$DEST"
    if [[ "$FORMAT" == "dir" ]]; then
      mkdir -p "$OUT_PATH"
    fi
  fi

  # Create temp staging dir for tar.gz
  if [[ "$FORMAT" == "tar.gz" ]]; then
    STAGE=$(mktemp -d)
    BACKUP_ROOT="$STAGE/$BASENAME"
    mkdir -p "$BACKUP_ROOT"
  else
    BACKUP_ROOT="$OUT_PATH"
  fi

  # Manifest header
  MANIFEST="$BACKUP_ROOT/MANIFEST.txt"
  if [[ "$DRY_RUN" != true ]]; then
    cat > "$MANIFEST" << EOF
AI Config Backup
================
Created: $(date -Iseconds)
Host: $(hostname)
User: $(whoami)
Format: $FORMAT

Tools backed up:
EOF
  fi

  for tool in windsurf codeium devin opencode ohmyopendevin copilot helpers; do
    count=$(count_items "$tool")
    if [[ "$count" -eq 0 ]]; then
      warn "$tool: no configs found — skipping"
      continue
    fi

    info "$tool: $count item(s)"
    if [[ "$DRY_RUN" != true ]]; then
      echo "  $tool: $count item(s)" >> "$MANIFEST"
    fi

    tool_dir="$BACKUP_ROOT/$tool"
    if [[ "$DRY_RUN" != true ]]; then
      mkdir -p "$tool_dir"
    fi

    # Dirs
    if [[ -n "${CONFIG_DIRS[$tool]:-}" ]]; then
      for d in ${CONFIG_DIRS[$tool]}; do
        if [[ -d "$d" ]]; then
          base=$(basename "$d")
          smart_copy "$d" "$tool_dir/$base"
        fi
      done
    fi

    # Individual files
    if [[ -n "${CONFIG_FILES[$tool]:-}" ]]; then
      for f in ${CONFIG_FILES[$tool]}; do
        if [[ -f "$f" ]]; then
          base=$(basename "$f")
          smart_copy "$f" "$tool_dir/$base"
        fi
      done
    fi

  done

  # Tar.gz wrap-up
  if [[ "$FORMAT" == "tar.gz" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would create tar.gz: $OUT_PATH from staging dir"
    else
      mkdir -p "$DEST"
      tar -czf "$OUT_PATH" -C "$STAGE" "$BASENAME"
      rm -rf "$STAGE"
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    dry "Save complete (no files written)"
  else
    ok "Backup written: $OUT_PATH"
  fi
  exit 0
fi

# ─── RESTORE ────────────────────────────────────────────────
if [[ "$ACTION" == "restore" ]]; then
  if [[ -z "$FROM" ]]; then
    echo "restore requires --from=PATH" >&2
    exit 1
  fi

  if [[ ! -e "$FROM" ]]; then
    echo "Backup not found: $FROM" >&2
    exit 1
  fi

  step "Restore — preview"
  info "Source: $FROM"

  # Determine if source is tar.gz or directory
  if [[ -f "$FROM" && "$FROM" == *.tar.gz ]]; then
    SRC_IS_TAR=true
    PREVIEW_DIR=$(mktemp -d)
    # Always extract for preview (read-only, safe even in dry-run)
    tar -xzf "$FROM" -C "$PREVIEW_DIR"
    # The tar likely contains a single top-level dir
    TOP_DIR=$(find "$PREVIEW_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
    RESTORE_ROOT="$TOP_DIR"
  else
    SRC_IS_TAR=false
    RESTORE_ROOT="$FROM"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    dry "Preview of backup contents:"
  else
    info "Backup contents:"
  fi

  for tool in windsurf codeium devin opencode ohmyopendevin copilot helpers; do
    tool_dir="$RESTORE_ROOT/$tool"
    if [[ -d "$tool_dir" ]]; then
      n=$(find "$tool_dir" -type f | wc -l)
      echo -e "  ${GREEN}${tool}${RESET}: $n file(s)"
      if [[ "$DRY_RUN" != true ]]; then
        ls -1 "$tool_dir" | sed 's/^/    /'
      fi
    else
      echo -e "  ${YELLOW}${tool}${RESET}: not present in backup"
    fi
  done

  if [[ "$DRY_RUN" == true ]]; then
    dry "Restore preview complete (no changes made)"
    exit 0
  fi

  # Confirmation
  if [[ "$AUTO_CONFIRM" != true ]]; then
    echo ""
    read -rp "Proceed with restore? This will OVERWRITE existing configs. [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Restore cancelled."
      if [[ "$SRC_IS_TAR" == true ]]; then
        rm -rf "$PREVIEW_DIR"
      fi
      exit 0
    fi
  fi

  step "Restore — applying"

  for tool in windsurf codeium devin opencode ohmyopendevin copilot helpers; do
    tool_dir="$RESTORE_ROOT/$tool"
    if [[ ! -d "$tool_dir" ]]; then
      continue
    fi

    info "Restoring $tool ..."

    # Restore dirs
    if [[ -n "${CONFIG_DIRS[$tool]:-}" ]]; then
      for d in ${CONFIG_DIRS[$tool]}; do
        base=$(basename "$d")
        src="$tool_dir/$base"
        if [[ -d "$src" ]]; then
          if [[ "$d" != "$HOME"/* ]] && [[ "$d" != /home/* ]]; then
            warn "  Refusing to rm -rf $d (not under /home)"
            continue
          fi
          backup_target "$d"
          rm -rf "$d"
          mkdir -p "$(dirname "$d")"
          cp -rp "$src" "$d"
          ok "  Restored dir  $d"
        fi
      done
    fi

    # Restore individual files
    if [[ -n "${CONFIG_FILES[$tool]:-}" ]]; then
      for f in ${CONFIG_FILES[$tool]}; do
        base=$(basename "$f")
        src="$tool_dir/$base"
        if [[ -f "$src" ]]; then
          backup_target "$f"
          mkdir -p "$(dirname "$f")"
          cp -p "$src" "$f"
          ok "  Restored file $f"
        fi
      done
    fi

  done

  if [[ "$SRC_IS_TAR" == true ]]; then
    rm -rf "$PREVIEW_DIR"
  fi

  ok "Restore complete"
  exit 0
fi

# ─── LIST ─────────────────────────────────────────────────────
if [[ "$ACTION" == "list" ]]; then
  step "Available backups"
  info "Looking in: $DEST"

  if [[ ! -d "$DEST" ]]; then
    warn "Directory does not exist: $DEST"
    exit 0
  fi

  found=0
  for entry in "$DEST"/ai-configs-*; do
    if [[ ! -e "$entry" ]]; then
      continue
    fi
    found=1
    name=$(basename "$entry")
    if [[ -d "$entry" ]]; then
      size=$(du -sh "$entry" 2>/dev/null | cut -f1)
    else
      size=$(du -sh "$entry" 2>/dev/null | cut -f1)
    fi
    echo -e "  ${GREEN}${name}${RESET}  (${size})"
  done

  if [[ "$found" -eq 0 ]]; then
    warn "No backups found in $DEST"
  fi
  exit 0
fi
