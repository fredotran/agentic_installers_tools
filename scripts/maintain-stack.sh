#!/usr/bin/env bash
# ============================================================
#  Stack Maintenance — Keep agentic tools up to date safely
#
#  Checks installed versions against stack-lock.json, shows
#  available updates, and applies them with compatibility guards.
#
#  Usage:
#    bash maintain-stack.sh               # Check status only
#    bash maintain-stack.sh --update      # Interactive update
#    bash maintain-stack.sh --update-all  # Update everything (careful!)
#    bash maintain-stack.sh --verify     # Verify MCP compatibility
#    bash maintain-stack.sh --lock       # Refresh lockfile from current state
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
info() { echo -e "${CYAN}→ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
err()  { echo -e "${RED}✖ $*${RESET}" >&2; }
step() { echo -e "\n${BOLD}${BLUE}══ $* ${RESET}"; }
dry()  { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }

# ─── Config ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LOCKFILE="$REPO_DIR/stack-lock.json"

if [[ ! -f "$LOCKFILE" ]]; then
  err "Lockfile not found: $LOCKFILE"
  exit 1
fi

# ─── Args ────────────────────────────────────────────────────
MODE="check"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)      MODE="update"; shift ;;
    --update-all)  MODE="update-all"; shift ;;
    --verify)      MODE="verify"; shift ;;
    --lock)        MODE="lock"; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    -h|--help)
      cat << 'HELP'
Usage: bash maintain-stack.sh [mode] [--dry-run]

Modes:
  (none)       Check status — show current vs locked vs latest
  --update     Interactive update — choose which packages to update
  --update-all Update all packages (respects pins)
  --verify     Verify MCP compatibility after an update
  --lock       Refresh lockfile from current installed state

Options:
  --dry-run    Preview changes without applying them

Examples:
  bash maintain-stack.sh                # See what's outdated
  bash maintain-stack.sh --update       # Update selectively
  bash maintain-stack.sh --verify       # Test MCP servers
HELP
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$DRY_RUN" == true ]]; then
  dry "Dry-run mode — no changes will be made"
fi

# ─── Helpers ─────────────────────────────────────────────────
get_lock_version() {
  python3 -c "
import json, sys
lock = json.load(open('$LOCKFILE'))
for section in ['python', 'npm', 'cargo']:
    if '$1' in lock.get(section, {}):
        print(lock[section]['$1']['version'])
        sys.exit(0)
print('not-in-lock')
"
}

get_lock_constraint() {
  python3 -c "
import json
lock = json.load(open('$LOCKFILE'))
for section in ['python', 'npm', 'cargo']:
    if '$1' in lock.get(section, {}):
        print(lock[section]['$1'].get('constraint', '*'))
        exit(0)
print('*')
"
}

get_pip_installed() {
  pip3 show "$1" 2>/dev/null | grep -E '^Version:' | awk '{print $2}' || echo "not-installed"
}

get_pip_latest() {
  python3 -c "
import json, urllib.request
try:
    data = json.load(urllib.request.urlopen('https://pypi.org/pypi/$1/json', timeout=10))
    print(data['info']['version'])
except Exception:
    print('unknown')
" 2>/dev/null
}

get_npm_installed() {
  local pkg="$1"
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  if [[ -d "$CONFIG_DIR/node_modules/$pkg" ]]; then
    cat "$CONFIG_DIR/node_modules/$pkg/package.json" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))"
  else
    echo "not-installed"
  fi
}

get_npm_latest() {
  npm view "$1" version 2>/dev/null || echo "unknown"
}

version_cmp() {
  # Returns: 0=equal, 1=first newer, 2=second newer
  python3 -c "
from packaging.version import Version
try:
    a = Version('$1')
    b = Version('$2')
    if a > b: print('1')
    elif a < b: print('2')
    else: print('0')
except Exception:
    print('?')
" 2>/dev/null || echo "?"
}

# ─── Status Check ──────────────────────────────────────────────
check_python() {
  step "Checking Python packages"
  python3 -c "from packaging.version import Version" 2>/dev/null || {
    info "Installing packaging library…"
    pip3 install packaging -q
  }

  local any_outdated=false

  python3 -c "
import json
lock = json.load(open('$LOCKFILE'))
for name, meta in lock.get('python', {}).items():
    print(name)
" | while read -r pkg; do
    local locked
    local installed
    local latest
    locked=$(get_lock_version "$pkg")
    installed=$(get_pip_installed "$pkg")
    latest=$(get_pip_latest "$pkg")

    if [[ "$installed" == "not-installed" ]]; then
      warn "$pkg: not installed (locked: $locked)"
      any_outdated=true
      continue
    fi

    local cmp_installed
    local cmp_latest
    cmp_installed=$(version_cmp "$installed" "$locked")
    cmp_latest=$(version_cmp "$latest" "$installed")

    if [[ "$cmp_installed" == "2" ]]; then
      # installed < locked (shouldn't happen unless manually downgraded)
      warn "$pkg: installed $installed < locked $locked"
      any_outdated=true
    elif [[ "$cmp_installed" == "1" ]]; then
      # installed > locked (user manually updated, or we need to refresh lock)
      if [[ "$cmp_latest" == "0" ]]; then
        info "$pkg: $installed (newer than lock $locked — run --lock to refresh)"
      else
        info "$pkg: $installed (newer than lock, latest is $latest)"
      fi
    else
      # installed == locked
      if [[ "$cmp_latest" == "2" ]]; then
        warn "$pkg: $installed — newer version available: $latest"
        any_outdated=true
      else
        ok "$pkg: $installed (up to date)"
      fi
    fi
  done
}

check_npm() {
  step "Checking npm packages"
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

  python3 -c "
import json
lock = json.load(open('$LOCKFILE'))
for name, meta in lock.get('npm', {}).items():
    print(name)
" | while read -r pkg; do
    local installed
    local latest
    installed=$(get_npm_installed "$pkg")
    latest=$(get_npm_latest "$pkg")

    if [[ "$installed" == "not-installed" ]]; then
      warn "$pkg: not installed"
    elif [[ "$latest" == "unknown" ]]; then
      info "$pkg: $installed (registry unreachable or private)"
    elif [[ "$installed" == "$latest" ]]; then
      ok "$pkg: $installed (up to date)"
    else
      warn "$pkg: $installed — newer available: $latest"
    fi
  done
}

check_git() {
  step "Checking git repos"
  python3 -c "
import json, os
lock = json.load(open('$LOCKFILE'))
for name, meta in lock.get('git', {}).items():
    dir_path = os.path.expanduser(meta['dir'])
    if os.path.isdir(dir_path):
        print(f'{name}:{dir_path}')
    else:
        print(f'{name}:NOT_INSTALLED')
" | while IFS=: read -r name dir; do
    if [[ "$dir" == "NOT_INSTALLED" ]]; then
      warn "$name: not cloned"
      continue
    fi
    local ahead_behind
    ahead_behind=$(cd "$dir" && git fetch -q 2>/dev/null && git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo "0 0")
    local behind
    behind=$(echo "$ahead_behind" | awk '{print $2}')
    if [[ "$behind" -gt 0 ]]; then
      warn "$name: $behind commit(s) behind upstream (cd $dir && git pull)"
    else
      ok "$name: up to date ($dir)"
    fi
  done
}

check_cargo() {
  step "Checking cargo packages"
  if ! command -v rtk &>/dev/null; then
    warn "rtk: not installed"
    return
  fi
  local installed
  installed=$(rtk --version 2>/dev/null | awk '{print $2}')
  if [[ -z "$installed" ]]; then
    warn "rtk: installed but version check failed"
    return
  fi
  ok "rtk: $installed (check cargo install-update or reinstall manually)"
}

# ─── Update ────────────────────────────────────────────────────
update_python() {
  step "Updating Python packages"

  # First, ensure fastmcp is pinned BEFORE updating anything
  local fastmcp_locked
  fastmcp_locked=$(get_lock_version "fastmcp")
  local fastmcp_constraint
  fastmcp_constraint=$(get_lock_constraint "fastmcp")

  if [[ "$fastmcp_constraint" == "=="* ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would pin fastmcp to $fastmcp_locked (prevents MCP breakage)"
    else
      info "Pinning fastmcp to $fastmcp_locked (compatibility guard)…"
      pip3 install "fastmcp==$fastmcp_locked" --break-system-packages -q \
        && ok "fastmcp pinned to $fastmcp_locked" \
        || warn "fastmcp pin failed"
    fi
  fi

  python3 -c "
import json
lock = json.load(open('$LOCKFILE'))
for name, meta in lock.get('python', {}).items():
    if name == 'fastmcp':
        continue  # already handled above
    print(name)
" | while read -r pkg; do
    local locked
    local constraint
    local installed
    local latest
    locked=$(get_lock_version "$pkg")
    constraint=$(get_lock_constraint "$pkg")
    installed=$(get_pip_installed "$pkg")
    latest=$(get_pip_latest "$pkg")

    if [[ "$installed" == "not-installed" ]]; then
      if [[ "$MODE" == "update-all" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
          dry "Would install $pkg$constraint (not currently installed)"
        else
          info "Installing $pkg$constraint…"
          pip3 install "$pkg$constraint" --break-system-packages -q \
            && ok "$pkg installed" || warn "$pkg install failed"
        fi
      fi
      continue
    fi

    local cmp
    cmp=$(version_cmp "$latest" "$installed")

    if [[ "$cmp" == "2" ]]; then
      # latest > installed
      if [[ "$MODE" == "update-all" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
          dry "Would upgrade $pkg: $installed → $latest"
        else
          info "Upgrading $pkg: $installed → $latest…"
          pip3 install "$pkg$constraint" --upgrade --break-system-packages -q \
            && ok "$pkg upgraded to $latest" || warn "$pkg upgrade failed"
        fi
      else
        # Interactive mode
        read -rp "Upgrade $pkg? ($installed → $latest) [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
          if [[ "$DRY_RUN" == true ]]; then
            dry "Would upgrade $pkg: $installed → $latest"
          else
            pip3 install "$pkg$constraint" --upgrade --break-system-packages -q \
              && ok "$pkg upgraded" || warn "$pkg upgrade failed"
          fi
        fi
      fi
    fi
  done
}

update_npm() {
  step "Updating npm packages"
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  PKG="bun i"
  command -v bun &>/dev/null || PKG="npm install"

  python3 -c "
import json
lock = json.load(open('$LOCKFILE'))
for name, meta in lock.get('npm', {}).items():
    print(name)
" | while read -r pkg; do
    if npm view "$pkg" --json >/dev/null 2>&1; then
      local latest
      latest=$(npm view "$pkg" version 2>/dev/null)
      if [[ "$DRY_RUN" == true ]]; then
        dry "Would update $pkg to $latest via $PKG"
      else
        info "Updating $pkg to $latest…"
        (cd "$CONFIG_DIR" && $PKG "$pkg@$latest" --silent) \
          && ok "$pkg updated" || warn "$pkg update failed"
      fi
    else
      info "$pkg: not on public registry (private/local — skip)"
    fi
  done
}

update_git() {
  step "Updating git repos"
  python3 -c "
import json, os
lock = json.load(open('$LOCKFILE'))
for name, meta in lock.get('git', {}).items():
    dir_path = os.path.expanduser(meta['dir'])
    if os.path.isdir(dir_path):
        print(f'{name}:{dir_path}')
" | while IFS=: read -r name dir; do
    if [[ "$DRY_RUN" == true ]]; then
      dry "Would git pull --ff-only in $dir"
    else
      info "Updating $name…"
      if git -C "$dir" pull --ff-only -q 2>/dev/null; then
        ok "$name updated"
      else
        warn "$name update had issues (may be up to date or have local changes)"
      fi
      if [[ -f "$dir/package.json" ]]; then
        (cd "$dir" && $PKG --silent) || warn "$name dependency update had issues"
      fi
    fi
  done
}

# ─── Verify ────────────────────────────────────────────────────
verify_mcp() {
  step "Verifying MCP compatibility"

  # Check fastmcp version first
  local fastmcp_ver
  fastmcp_ver=$(get_pip_installed "fastmcp")
  local fastmcp_locked
  fastmcp_locked=$(get_lock_version "fastmcp")
  local fastmcp_cmp
  fastmcp_cmp=$(version_cmp "$fastmcp_ver" "$fastmcp_locked")

  if [[ "$fastmcp_cmp" == "1" ]]; then
    warn "fastmcp is $fastmcp_ver but locked at $fastmcp_locked — MCP servers may be broken!"
    warn "Run: pip3 install 'fastmcp==$fastmcp_locked' --break-system-packages --force-reinstall"
  else
    ok "fastmcp $fastmcp_ver (compatible)"
  fi

  # Quick smoke test of MCP servers
  if command -v code-review-graph &>/dev/null; then
    local out
    out=$(timeout 5 code-review-graph mcp 2>&1 || true)
    if echo "$out" | grep -q "Starting MCP server"; then
      ok "code-review-graph MCP starts successfully"
    else
      warn "code-review-graph MCP had issues on startup"
    fi
  fi

}

# ─── Lock Refresh ────────────────────────────────────────────
refresh_lock() {
  step "Refreshing lockfile from current state"
  if [[ "$DRY_RUN" == true ]]; then
    dry "Would refresh $LOCKFILE from installed versions"
    return
  fi

  python3 - "$LOCKFILE" << 'PY'
import json, sys, subprocess

lockfile = sys.argv[1]
with open(lockfile) as f:
    lock = json.load(f)

# Update python versions from pip
for pkg in lock.get("python", {}):
    try:
        result = subprocess.run(
            ["pip3", "show", pkg],
            capture_output=True, text=True, timeout=10
        )
        for line in result.stdout.splitlines():
            if line.startswith("Version:"):
                ver = line.split(":", 1)[1].strip()
                old = lock["python"][pkg]["version"]
                if old != ver:
                    print(f"  {pkg}: {old} → {ver}")
                    lock["python"][pkg]["version"] = ver
                break
    except Exception:
        pass

# Update npm versions
import os
config_dir = os.path.expanduser("~/.config/opencode")
for pkg in lock.get("npm", {}):
    pkg_json = os.path.join(config_dir, "node_modules", pkg, "package.json")
    if os.path.isfile(pkg_json):
        try:
            with open(pkg_json) as f:
                ver = json.load(f).get("version", "unknown")
            old = lock["npm"][pkg]["version"]
            if old != ver:
                print(f"  {pkg}: {old} → {ver}")
                lock["npm"][pkg]["version"] = ver
        except Exception:
            pass

# Update lastVerified
from datetime import datetime
lock["lastVerified"] = datetime.now().strftime("%Y-%m-%d")

with open(lockfile, "w") as f:
    json.dump(lock, f, indent=2)
    f.write("\n")

print(f"\nLockfile refreshed: {lockfile}")
PY

  ok "Lockfile updated"
}

# ─── Main ────────────────────────────────────────────────────
case "$MODE" in
  check)
    check_python
    check_npm
    check_git
    check_cargo
    step "Summary"
    info "Run with --update for interactive updates"
    info "Run with --verify after any update to check MCP health"
    ;;
  update|update-all)
    check_python
    check_npm
    check_git
    check_cargo
    step "Starting updates"
    update_python
    update_npm
    update_git
    step "Post-update verification"
    verify_mcp
    info "Done. Restart opencode/Devin for changes to take effect."
    ;;
  verify)
    verify_mcp
    ;;
  lock)
    refresh_lock
    ;;
esac
