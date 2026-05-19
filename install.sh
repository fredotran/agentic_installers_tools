#!/usr/bin/env bash
# ============================================================
#  Agentic Coding Tools — Full Installer
#
#  Installs the complete AI-coding stack:
#    1. opencode CLI (if missing)
#    2. oh-my-openagent plugins
#    3. token optimizers (setup-token-optimizer.sh)
#    4. obra/superpowers
#
#  Usage: bash install.sh [options]
#
#  Options:
#    --skip-opencode          Skip opencode CLI install/check
#    --skip-openagent         Skip oh-my-openagent setup
#    --skip-token-optimizer   Skip token optimizer setup
#    --force                  Overwrite existing configs without prompting
#    --dry-run                Preview changes without applying them
#    --yes / -y               Auto-answer "yes" to all prompts (for CI)
#    -h, --help               Show this help
#
#  Environment:
#    AC_YES=1                 Same as --yes (useful in CI)
# ============================================================

set -euo pipefail

# ─── Colors ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
info() { echo -e "${CYAN}→ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
err()  { echo -e "${RED}✖ $*${RESET}" >&2; }
step() { echo -e "\n${BOLD}${BLUE}══ $* ${RESET}"; }
dry()  { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }

ask() {
  if [[ "${AC_YES:-0}" == "1" || "${AUTO_YES:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    return 1
  fi
  local ans
  read -rp "$(echo -e "${CYAN}? $* [Y/n]: ${RESET}")" ans
  [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]
}

require() {
  command -v "$1" &>/dev/null || { err "Required: '$1' not found."; exit 1; }
}

append_if_missing() {
  [[ -f "$1" ]] && [[ -s "$1" ]] && [[ "$(tail -c 1 "$1" | wc -l)" -eq 0 ]] && echo "" >> "$1"
  grep -qxF "$2" "$1" 2>/dev/null || echo "$2" >> "$1"
}

# ─── Args ────────────────────────────────────────────────────
SKIP_OPENCODE=false
SKIP_OPENAGENT=false
SKIP_TOKENS=false
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-opencode)          SKIP_OPENCODE=true; shift ;;
    --skip-openagent)         SKIP_OPENAGENT=true; shift ;;
    --skip-token-optimizer)   SKIP_TOKENS=true; shift ;;
    --force)                  FORCE=true; shift ;;
    --dry-run)                DRY_RUN=true; shift ;;
    --yes|-y)                 AC_YES=1; shift ;;
    -h|--help)
      sed -n '/^#  Usage:/,/^#  Environment:/p' "$0" | sed 's/^#  //; s/^# //; s/^#$//; /^$/d'
      exit 0
      ;;
    *) warn "Unknown option: $1"; shift ;;
  esac
done

if [[ "$DRY_RUN" == true ]]; then
  dry "Dry-run mode — no changes will be made"
fi

# ─── Paths ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_SCRIPT="$SCRIPT_DIR/scripts/setup-token-optimizer.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
BACKUP_DIR="$HOME/.local/share/agentic-coding-tools/backups"

# Detect shell rc file
has_shell_in_tree() {
  local target="$1" pid=$$
  while [[ "$pid" -gt 1 ]]; do
    local comm
    comm=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ') || break
    [[ "$comm" == "$target" ]] && return 0
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || break
    [[ -z "$pid" || "$pid" -le 1 ]] && break
  done
  return 1
}

if has_shell_in_tree "zsh"; then
  SHELL_RC="$HOME/.zshrc"
elif has_shell_in_tree "bash"; then
  SHELL_RC="$HOME/.bashrc"
else
  SHELL_RC="$HOME/.zshrc"
  [[ "$SHELL" == *bash* ]] && SHELL_RC="$HOME/.bashrc"
fi

# ─── State tracking ─────────────────────────────────────────
declare -a CHANGES=()
declare -a SKIPPED=()
changed() { CHANGES+=("$1"); }
skipped() { SKIPPED+=("$1"); }

# ─── Helpers ────────────────────────────────────────────────
backup_config() {
  local src="$1"
  if [[ -f "$src" ]]; then
    local bak="$BACKUP_DIR/$(basename "$src").$(date +%Y%m%d_%H%M%S).bak"
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would back up $(basename "$src") → $bak"
    else
      mkdir -p "$BACKUP_DIR"
      cp "$src" "$bak"
      ok "Backed up $(basename "$src") → $bak"
    fi
  fi
}

validate_json() {
  local path="$1"
  python3 -c "import json; json.load(open('$path'))" 2>/dev/null && return 0
  err "Invalid JSON: $path"
  return 1
}

merge_opencode_plugin() {
  local config_file="$1"
  local plugin_name="oh-my-openagent@latest"

  if [[ "$DRY_RUN" == true ]]; then
    if grep -q '"oh-my-openagent' "$config_file" 2>/dev/null; then
      dry "Plugin already present in $(basename "$config_file")"
    else
      dry "Would add '$plugin_name' to $(basename "$config_file")"
    fi
    return 0
  fi

  if grep -q '"oh-my-openagent' "$config_file" 2>/dev/null; then
    ok "Plugin already present in $(basename "$config_file")"
    return 0
  fi

  # Use Python to safely merge into JSON/JSONC
  local result
  result=$(python3 -c "
import json, re, sys
path = '$config_file'
plugin = '$plugin_name'

try:
    with open(path, 'r') as f:
        raw = f.read()
    clean = re.sub(r'//.*', '', raw)
    clean = re.sub(r'/\*[\s\S]*?\*/', '', clean)
    data = json.loads(clean)
except Exception as e:
    print(f'Parse error: {e}', file=sys.stderr)
    sys.exit(1)

plugins = data.get('plugin', [])
if isinstance(plugins, str):
    plugins = [plugins]
if plugin not in plugins:
    plugins.insert(0, plugin)
    data['plugin'] = plugins
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print('merged')
else:
    print('already-present')
" 2>/dev/null) || {
    warn "Python merge failed — falling back to sed"
    sed -i 's/"plugin": \[/"plugin": [\n    "oh-my-openagent@latest",/' "$config_file" 2>/dev/null || true
    result="merged-fallback"
  }

  if [[ "$result" == "merged" ]]; then
    ok "Plugin entry added to $(basename "$config_file")"
  else
    ok "Plugin already present in $(basename "$config_file")"
  fi
}

build_auth_json() {
  local out="$1"
  shift
  python3 -c "
import json, sys
entries = []
for arg in sys.argv[1:]:
    parts = arg.split('|', 1)
    if len(parts) == 2:
        entries.append(parts)
data = {k: v for k, v in entries}
json.dump(data, open('$out', 'w'), indent=2)
" "$@"
}

# ─── Pre-flight checks ──────────────────────────────────────
step "Phase 0 — Pre-flight Checks"

require git
require python3

# Verify write access to config dirs
for dir in "$CONFIG_DIR" "$HOME/.local/share/opencode" "$BACKUP_DIR"; do
  if [[ "$DRY_RUN" == false ]]; then
    if ! mkdir -p "$dir" 2>/dev/null; then
      err "Cannot create directory: $dir"
      info "Check permissions or set XDG_CONFIG_HOME / HOME correctly"
      exit 1
    fi
  fi
done
ok "Write access verified"

if command -v bun &>/dev/null; then
  PKG_MGR="bun"
  PKG_INSTALL="bun i -g"
  ok "bun $(bun --version)"
elif command -v npm &>/dev/null; then
  PKG_MGR="npm"
  PKG_INSTALL="npm install -g"
  ok "npm $(npm -v)"
else
  err "Neither bun nor npm found. Install Node.js first:"
  info "  curl -fsSL https://bun.sh/install | bash"
  info "  or: sudo apt install nodejs npm"
  exit 1
fi

# uvx for MCP servers
if ! command -v uvx &>/dev/null; then
  info "Installing uv/uvx…"
  pip3 install uv -q 2>/dev/null && ok "uv installed" || warn "uv install failed (non-fatal)"
fi

# ─── Phase 1 — opencode CLI ──────────────────────────────────
step "Phase 1 — opencode CLI"

if [[ "$SKIP_OPENCODE" == true ]]; then
  skipped "opencode CLI"
else
  if command -v opencode &>/dev/null; then
    local_version=$(opencode --version 2>/dev/null || echo 'unknown')
    ok "opencode already installed: $local_version"
    info "Location: $(which opencode)"
    skipped "opencode CLI (already installed)"
  else
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would install opencode-ai@latest via $PKG_MGR"
    else
      info "Installing opencode CLI via $PKG_MGR…"
      if [[ "$PKG_MGR" == "bun" ]]; then
        bun i -g opencode-ai@latest 2>/dev/null && ok "opencode installed via bun" || {
          err "bun install failed"; exit 1;
        }
      else
        npm install -g opencode-ai@latest 2>/dev/null && ok "opencode installed via npm" || {
          err "npm install failed"; exit 1;
        }
      fi

      export PATH="$HOME/.bun/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
      hash -r 2>/dev/null || true

      if command -v opencode &>/dev/null; then
        ok "opencode installed: $(opencode --version 2>/dev/null || echo 'unknown')"
        changed "opencode CLI installed"
      else
        err "opencode still not in PATH after install."
        info "Try: export PATH=\"$HOME/.bun/bin:\$PATH\" and re-run."
        exit 1
      fi
    fi
  fi
fi

# ─── Phase 2 — Configure opencode ────────────────────────────
step "Phase 2 — Configure opencode"

AUTH_FILE="$HOME/.local/share/opencode/auth.json"
mkdir -p "$(dirname "$AUTH_FILE")"

# Check existing auth
CONFIGURE=false
if [[ -f "$AUTH_FILE" ]] && [[ -s "$AUTH_FILE" ]]; then
  ok "Existing auth.json found"
  if [[ "$FORCE" == true ]]; then
    info "--force set: re-configuring API keys"
    CONFIGURE=true
  elif ask "Re-configure API keys?"; then
    CONFIGURE=true
  fi
else
  info "No auth.json found — first-time setup."
  CONFIGURE=true
fi

if [[ "$CONFIGURE" == true ]]; then
  info "Supported providers: openai, anthropic, google, github-copilot, xai"
  info "(You can add multiple — leave blank when done)"
  echo ""

  declare -a ENTRIES=()
  while true; do
    read -rp "  Provider name (or Enter to finish): " provider
    [[ -z "$provider" ]] && break

    read -rp "  API key for $provider: " key
    [[ -z "$key" ]] && { warn "Empty key, skipping."; continue; }

    ENTRIES+=("$provider|$key")
  done

  if [[ ${#ENTRIES[@]} -gt 0 ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would write auth.json with ${#ENTRIES[@]} provider(s)"
    else
      build_auth_json "$AUTH_FILE" "${ENTRIES[@]}"
      validate_json "$AUTH_FILE"
      ok "auth.json written with ${#ENTRIES[@]} provider(s)"
      changed "auth.json configured"
    fi
  else
    warn "No API keys configured. You can run 'opencode auth' later."
  fi
else
  skipped "auth.json (kept existing)"
fi

# Ensure auth.json is not tracked by git
if [[ "$DRY_RUN" == false ]]; then
  append_if_missing "$HOME/.gitignore" ".local/share/opencode/auth.json"
  append_if_missing "$HOME/.gitignore" ".config/opencode/auth.json"
fi

# ─── Phase 3 — oh-my-openagent ───────────────────────────────
step "Phase 3 — oh-my-openagent"

if [[ "$SKIP_OPENAGENT" == true ]]; then
  skipped "oh-my-openagent"
else
  OMA_CONFIG="$CONFIG_DIR/oh-my-openagent.json"

  INSTALL_OMA=false
  if [[ -f "$OMA_CONFIG" ]]; then
    ok "oh-my-openagent config found: $OMA_CONFIG"
    if [[ "$FORCE" == true ]]; then
      info "--force set: overwriting oh-my-openagent config"
      INSTALL_OMA=true
    elif ask "Re-install / update oh-my-openagent config?"; then
      INSTALL_OMA=true
    fi
  else
    INSTALL_OMA=true
  fi

  if [[ "$INSTALL_OMA" == true ]]; then
    # Install package
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would install oh-my-opencode@latest via $PKG_MGR"
    else
      info "Installing oh-my-openagent plugin package…"
      if [[ "$PKG_MGR" == "bun" ]]; then
        bun i -g oh-my-opencode@latest 2>/dev/null && ok "oh-my-opencode installed" || warn "global install failed (plugin may resolve via opencode)"
      else
        npm install -g oh-my-opencode@latest 2>/dev/null && ok "oh-my-opencode installed" || warn "global install failed (plugin may resolve via opencode)"
      fi
      changed "oh-my-opencode package"
    fi

    # Resolve active opencode config file (.jsonc takes precedence)
    OPENCODE_CONF=""
    if [[ -f "$CONFIG_DIR/opencode.jsonc" ]]; then
      OPENCODE_CONF="$CONFIG_DIR/opencode.jsonc"
    elif [[ -f "$CONFIG_DIR/opencode.json" ]]; then
      OPENCODE_CONF="$CONFIG_DIR/opencode.json"
    fi

    if [[ -n "$OPENCODE_CONF" ]]; then
      backup_config "$OPENCODE_CONF"
      merge_opencode_plugin "$OPENCODE_CONF"
      changed "$(basename "$OPENCODE_CONF") plugin list"
    else
      # Create fresh opencode.json
      if [[ "$DRY_RUN" == true ]]; then
        dry "Would create opencode.json with oh-my-openagent"
      else
        cat > "$CONFIG_DIR/opencode.json" << 'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    "oh-my-openagent@latest"
  ]
}
JSON
        validate_json "$CONFIG_DIR/opencode.json"
        ok "opencode.json created with oh-my-openagent"
        changed "opencode.json created"
      fi
    fi

    # Write oh-my-openagent.json
    if [[ -f "$OMA_CONFIG" ]]; then
      backup_config "$OMA_CONFIG"
    fi

    if [[ "$DRY_RUN" == true ]]; then
      dry "Would write oh-my-openagent.json"
    else
      cat > "$OMA_CONFIG" << 'OMA'
{
  "$schema": "https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/oh-my-opencode.schema.json",
  "skills": {
    "git_master": {
      "commit_footer": false,
      "include_co_authored_by": false
    }
  },
  "agents": {
    "sisyphus": {
      "model": "anthropic/claude-opus-4-7",
      "variant": "max",
      "fallback_models": [
        { "model": "github-copilot/claude-opus-4.6", "variant": "max" },
        { "model": "github-copilot/gpt-5.4", "variant": "medium" }
      ]
    },
    "hephaestus": {
      "model": "github-copilot/gpt-5.3-codex",
      "variant": "medium"
    },
    "oracle": {
      "model": "github-copilot/gpt-5.4",
      "variant": "high",
      "fallback_models": [
        { "model": "github-copilot/gemini-3.1-pro-preview", "variant": "high" },
        { "model": "anthropic/claude-opus-4-6", "variant": "max" },
        { "model": "github-copilot/claude-opus-4.6", "variant": "max" }
      ]
    },
    "explore": {
      "model": "anthropic/claude-haiku-4-5"
    },
    "atlas": {
      "model": "anthropic/claude-sonnet-4-6",
      "fallback_models": [
        { "model": "github-copilot/claude-sonnet-4-6" },
        { "model": "github-copilot/gpt-5.5", "variant": "medium" }
      ]
    }
  },
  "categories": {
    "deep": {
      "model": "github-copilot/gpt-5.5",
      "variant": "medium",
      "fallback_models": [
        { "model": "anthropic/claude-opus-4-6", "variant": "max" },
        { "model": "github-copilot/claude-opus-4-6", "variant": "max" }
      ]
    },
    "quick": {
      "model": "github-copilot/gpt-5.4-mini",
      "fallback_models": [
        { "model": "anthropic/claude-haiku-4-5" },
        { "model": "github-copilot/claude-haiku-4.5" }
      ]
    }
  }
}
OMA
      validate_json "$OMA_CONFIG"
      ok "oh-my-openagent.json written"
      changed "oh-my-openagent.json configured"
    fi
  else
    skipped "oh-my-openagent.json (kept existing)"
  fi
fi

# ─── Phase 4 — Token Optimizers ──────────────────────────────
step "Phase 4 — Token Optimizers"

if [[ "$SKIP_TOKENS" == true ]]; then
  skipped "token optimizers"
else
  if [[ ! -f "$TOKEN_SCRIPT" ]]; then
    err "Token optimizer script not found: $TOKEN_SCRIPT"
    info "Expected: Agentic_Coding_Tools/scripts/setup-token-optimizer.sh"
    exit 1
  fi

  ok "Found token optimizer script"

  # Build token optimizer args
  TOKEN_ARGS=()
  [[ "$DRY_RUN" == true ]] && TOKEN_ARGS+=("--dry-run")

  if [[ "$DRY_RUN" == true ]]; then
    dry "Would run: bash $TOKEN_SCRIPT ${TOKEN_ARGS[*]}"
  else
    info "Running: bash $TOKEN_SCRIPT ${TOKEN_ARGS[*]}"
    echo ""
    if bash "$TOKEN_SCRIPT" "${TOKEN_ARGS[@]}"; then
      ok "Token optimizer setup completed"
      changed "token optimizers (DCP, Skillful, Conductor, RTK, MCPs)"
    else
      err "Token optimizer setup failed (exit code: $?)"
      warn "You can re-run manually: bash $TOKEN_SCRIPT ${TOKEN_ARGS[*]}"
    fi
  fi
fi

# ─── Phase 4.5 — obra/superpowers ─────────────────────────────
step "Phase 4.5 — obra/superpowers"

if [[ "$DRY_RUN" == true ]]; then
  dry "Would install obra/superpowers via $PKG_MGR"
else
  info "Installing obra/superpowers via $PKG_MGR…"
  if [[ "$PKG_MGR" == "bun" ]]; then
    bun i -g @obra/superpowers -q 2>/dev/null && ok "obra/superpowers installed via bun" || warn "obra/superpowers bun install failed (non-fatal)"
  else
    npm install -g @obra/superpowers -q 2>/dev/null && ok "obra/superpowers installed via npm" || warn "obra/superpowers npm install failed (non-fatal)"
  fi
  changed "obra/superpowers"
fi

# ─── Phase 5 — Final Summary ─────────────────────────────────
step "Setup Complete"

echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Agentic Coding Tools — Installation Complete${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo ""

if [[ ${#CHANGES[@]} -gt 0 ]]; then
  echo -e "${CYAN}  Changes made:${RESET}"
  for c in "${CHANGES[@]}"; do
    echo -e "    ${GREEN}•${RESET} $c"
  done
  echo ""
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo -e "${CYAN}  Skipped (already present or opted out):${RESET}"
  for s in "${SKIPPED[@]}"; do
    echo -e "    ${YELLOW}•${RESET} $s"
  done
  echo ""
fi

echo -e "${CYAN}  Quick start:${RESET}"
echo -e "  ${BOLD}source $SHELL_RC${RESET}"
echo -e "  ${BOLD}opencode${RESET}                 # Start an optimized session"
echo -e "  ${BOLD}opencode --version${RESET}       # Verify installation"
echo ""
echo -e "${CYAN}  Useful commands:${RESET}"
echo -e "  ${BOLD}opencode auth${RESET}            # Manage API keys"
echo -e "  ${BOLD}opencode plugin list${RESET}       # List loaded plugins"
echo ""
echo -e "${CYAN}  Re-run options:${RESET}"
echo -e "  bash $SCRIPT_DIR/install.sh --force               # Overwrite all configs"
echo -e "  bash $SCRIPT_DIR/install.sh --skip-opencode --skip-openagent"
echo -e "  AC_YES=1 bash $SCRIPT_DIR/install.sh              # Non-interactive mode"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
