#!/usr/bin/env bash
# ============================================================
#  OpenCode Token Optimizer — Full Automated Benchmark Suite
#
#  ONE script does everything:
#    1. Install monitoring tools (ccusage, tokenscope, etc.)
#    2. Run baseline benchmark (optimizer OFF)
#    3. Install the full optimizer stack
#    4. Run optimized benchmark (optimizer ON)
#    5. Print side-by-side comparison report
#
#  Usage: ./run-benchmark.sh [--project /path/to/project]
#         ./run-benchmark.sh           (uses current directory)
# ============================================================

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────
PROJECT_DIR="$(pwd)"
SKIP_BASELINE=0
SKIP_OPTIMIZED=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_DIR="${2:-$(pwd)}"; shift 2 ;;
    --project=*) PROJECT_DIR="${1#*=}"; shift ;;
    --skip-baseline) SKIP_BASELINE=1; shift ;;
    --skip-optimized) SKIP_OPTIMIZED=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--project /path/to/project] [--skip-baseline] [--skip-optimized] [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; shift ;;
  esac
done

PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd || echo "$PROJECT_DIR")"
if [[ ! -d "$PROJECT_DIR" ]]; then
  err "Project directory does not exist: $PROJECT_DIR"
  exit 1
fi
[[ "$DRY_RUN" -eq 1 ]] && echo "DRY RUN mode — no changes will be made"

BENCH_DIR="$HOME/.local/share/opencode-benchmark"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DIR="$CONFIG_DIR/plugin"
SKILLS_DIR="$CONFIG_DIR/skills"
CONFIG_FILE="$CONFIG_DIR/opencode.jsonc"
AGENTS_MD="$CONFIG_DIR/AGENTS.md"
RESULTS_CSV="$BENCH_DIR/results.csv"
RESULTS_JSON="$BENCH_DIR/results.json"
# Detect the user's actual interactive shell (not just $SHELL, which may lie)
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
TS=$(date +%Y%m%d_%H%M%S)

# ─── Prune old backups ───────────────────────────────────────
BACKUP_RETENTION_DAYS=7

prune_old_backups() {
  local dir="$1"
  local days="${2:-7}"
  [[ -d "$dir" ]] || return 0
  local count=0 file
  while IFS= read -r -d '' file || [[ -n "$file" ]]; do
    rm -f "$file"
    count=$((count + 1))
  done < <(find "$dir" -maxdepth 1 -name '*.bak_*' -mtime +"$days" -print0 2>/dev/null)
  [[ "$count" -gt 0 ]] && info "Pruned $count backup(s) older than $days day(s) in $dir"
  return 0
}

# ─── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
info() { echo -e "${CYAN}→ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
err()  { echo -e "${RED}✖ $*${RESET}" >&2; }
step() { echo -e "\n${BOLD}${BLUE}╔══ $* ══╗${RESET}"; }

require() { command -v "$1" &>/dev/null || { err "Required: '$1' not found. Install it first."; exit 1; }; }
append_if_missing() {
  # Ensure file ends with a newline before appending to avoid concatenation bugs
  [[ -f "$1" ]] && [[ -s "$1" ]] && [[ "$(tail -c 1 "$1" | wc -l)" -eq 0 ]] && echo "" >> "$1"
  grep -qxF "$2" "$1" 2>/dev/null || echo "$2" >> "$1"
}

# ─── Cleanup helpers ─────────────────────────────────────────
PHASE="init"
BACKUP_PAIRS=()

backup_and_disable() {
  local src="$1"
  if [[ -f "$src" ]]; then
    local bak="${src}.bak_${TS}"
    mv "$src" "$bak"
    BACKUP_PAIRS+=("$bak|$src")
    info "Disabled and backed up ${src} → ${bak}"
  fi
}

backup_keep() {
  local src="$1"
  if [[ -f "$src" ]]; then
    local bak="${src}.bak_${TS}"
    cp "$src" "$bak"
    BACKUP_PAIRS+=("$bak|$src")
    info "Backed up ${src} → ${bak}"
  fi
}

restore_backups() {
  for pair in "${BACKUP_PAIRS[@]}"; do
    IFS='|' read -r bak orig <<< "$pair"
    [[ -f "$bak" ]] && mv -f "$bak" "$orig" 2>/dev/null && info "Restored $orig"
  done
}

cleanup_trap() {
  if [[ "$PHASE" == "baseline" ]]; then
    warn "Interrupted during baseline — restoring original configs"
    restore_backups
  fi
}
trap cleanup_trap INT TERM EXIT

# ─── Detect package manager ───────────────────────────────────
PKG="bun i"; BUNX="bunx"
command -v bun &>/dev/null || { PKG="npm install"; BUNX="npx --yes"; }

# ─── Helper: extract last session tokens from ccusage ─────────
get_last_session_tokens() {
  # Returns JSON-like: input output cache total
  ccusage session --last 1 --json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
s = data[0] if data else {}
print(s.get('inputTokens',0), s.get('outputTokens',0), s.get('cacheTokens',0), s.get('totalTokens',0))
" 2>/dev/null || echo "0 0 0 0"
}

# ─── Helper: run an opencode task headlessly ──────────────────
run_task() {
  local prompt="$1" timeout_s="${2:-120}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] Would run: opencode --print '$prompt'"
    return 0
  fi
  # Try headless opencode methods in order of preference
  if opencode --help 2>/dev/null | grep -q -- '--print'; then
    timeout "$timeout_s" opencode --print "$prompt" 2>/dev/null || true
  elif opencode --help 2>/dev/null | grep -q -- '--no-interactive'; then
    timeout "$timeout_s" opencode --no-interactive "$prompt" 2>/dev/null || true
  else
    warn "opencode headless mode not detected — skipping task"
  fi
}

# ════════════════════════════════════════════════════════════
step "PHASE 0 — Setup & prerequisites"
# ════════════════════════════════════════════════════════════
require node; require git; require python3; require opencode

command -v uvx &>/dev/null || { info "Installing uvx…"; pip3 install uv -q; ok "uvx ready"; }
mkdir -p "$BENCH_DIR" "$CONFIG_DIR" "$PLUGIN_DIR" "$SKILLS_DIR"
prune_old_backups "$CONFIG_DIR" "$BACKUP_RETENTION_DAYS"
prune_old_backups "$HOME/.local/share/opencode-conductor" "$BACKUP_RETENTION_DAYS"
ok "Project: $PROJECT_DIR"
ok "Benchmark dir: $BENCH_DIR"

# ─── Install monitoring tools ─────────────────────────────────
step "PHASE 0.1 — Installing token monitoring tools"

cd "$CONFIG_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would install opencode-tokenscope via $PKG"
  info "[dry-run] Would install opencode-token-monitor via $PKG"
  if command -v bun &>/dev/null; then
    info "[dry-run] Would install ccusage via bun"
  elif command -v npm &>/dev/null; then
    info "[dry-run] Would install ccusage via npm"
  fi
  info "[dry-run] Would run vibeusage init"
else
  $PKG opencode-tokenscope -q 2>/dev/null && ok "opencode-tokenscope" || warn "opencode-tokenscope install failed"
  $PKG opencode-token-monitor -q 2>/dev/null && ok "opencode-token-monitor" || warn "opencode-token-monitor install failed"

  if command -v bun &>/dev/null; then
    bun i -g ccusage -q 2>/dev/null && ok "ccusage (bun)" || warn "ccusage bun install failed"
  elif command -v npm &>/dev/null; then
    npm install -g ccusage -q 2>/dev/null && ok "ccusage (npm)" || warn "ccusage npm install failed"
  else
    warn "No bun or npm found — ccusage skipped"
  fi

  $BUNX vibeusage init 2>/dev/null && ok "VibeUsage" || warn "VibeUsage init failed (non-fatal)"
fi

# ─── Define benchmark tasks (run headlessly with --print) ─────
step "PHASE 0.2 — Defining benchmark task prompts"

# These are generic prompts. They will be run with opencode --print
# against your actual project so results are real, not synthetic.
declare -A TASKS
TASKS[task1]="List all unique function and class names defined in this project. Be terse, no explanation."
TASKS[task2]="Find all files that import or depend on the most-used module in this project. One-line answer per file."
TASKS[task3]="Add a TODO comment to the first function in the largest source file. Output only the diff."
TASKS[task4]="In one sentence, explain what the entry point of this project does."
TASKS[task5]="List the top 3 files with the most lines of code. Filename and line count only."

TASK_ORDER=(task1 task2 task3 task4 task5)

cat > "$RESULTS_CSV" << 'CSV'
task,phase,input_tokens,output_tokens,cache_tokens,total_tokens,duration_s
CSV
ok "Results CSV initialized at $RESULTS_CSV"

# ════════════════════════════════════════════════════════════
step "PHASE 1 — Baseline benchmark (optimizer OFF)"
# ════════════════════════════════════════════════════════════

if [[ "$SKIP_BASELINE" -eq 1 ]]; then
  info "Skipping baseline (--skip-baseline)"
else
  PHASE="baseline"

  backup_keep "$CONFIG_FILE"
  cat > "$CONFIG_FILE" << 'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["opencode-tokenscope", "opencode-token-monitor"],
  "instructions": []
}
JSON
  ok "Baseline config written (no optimizer plugins)"

  backup_and_disable "$AGENTS_MD"
  backup_and_disable "$PLUGIN_DIR/auto-init.ts"

  info "Running baseline tasks against: $PROJECT_DIR"
  cd "$PROJECT_DIR"

  for task_id in "${TASK_ORDER[@]}"; do
    prompt="${TASKS[$task_id]}"
    info "Baseline › $task_id: $prompt"

    T_START=$(date +%s)
    run_task "$prompt" 120
    T_END=$(date +%s)
    DURATION=$(( T_END - T_START ))

    read -r IN_TOK OUT_TOK CACHE_TOK TOTAL_TOK <<< "$(get_last_session_tokens)"

    echo "${task_id},baseline,${IN_TOK},${OUT_TOK},${CACHE_TOK},${TOTAL_TOK},${DURATION}" >> "$RESULTS_CSV"
    ok "$task_id baseline: ${TOTAL_TOK} total tokens in ${DURATION}s"
    sleep 2
  done

  ok "Baseline phase complete"
fi

# ════════════════════════════════════════════════════════════
step "PHASE 2 — Installing optimizer stack"
# ════════════════════════════════════════════════════════════

# ── 1. DCP ───
cd "$CONFIG_DIR"
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would install opencode-dcp-plugin via $PKG"
else
  $PKG opencode-dcp-plugin -q 2>/dev/null && ok "DCP installed" || warn "DCP install failed"
fi

# ── 2. Skillful ───
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would install opencode-skillful via $PKG"
else
  $PKG opencode-skillful -q 2>/dev/null && ok "Skillful installed" || warn "Skillful install failed"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would write token-saver skill to $SKILLS_DIR/token-saver.md"
else
  cat > "$SKILLS_DIR/token-saver.md" << 'SKILL'
---
description: Token-efficient mode — AST-first, terse output, diffs not full files
---
You are in token-saver mode:
- Use code-review-graph MCP tools for all symbol lookups and file searches
- Never read full files — use AST summaries
- Output diffs (udiff), not full rewrites
- Keep responses terse — no padding, no repetition
SKILL
  ok "token-saver skill written"
fi

# ── 3. Conductor ───
CONDUCTOR_DIR="$HOME/.local/share/opencode-conductor"
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ -d "$CONDUCTOR_DIR" ]]; then
    info "[dry-run] Would update Conductor in $CONDUCTOR_DIR"
  else
    info "[dry-run] Would clone Conductor to $CONDUCTOR_DIR"
  fi
else
  if [[ -d "$CONDUCTOR_DIR" ]]; then
    git -C "$CONDUCTOR_DIR" pull --ff-only -q 2>/dev/null && ok "Conductor updated" || warn "Conductor update failed"
  else
    git clone -q https://github.com/derekbar90/opencode-conductor "$CONDUCTOR_DIR" 2>/dev/null \
      && ok "Conductor cloned" || warn "Conductor clone failed"
  fi
  if [[ -d "$CONDUCTOR_DIR" ]]; then
    (cd "$CONDUCTOR_DIR" && $PKG -q 2>/dev/null) || true
    ok "Conductor ready"
  fi
fi

# ── 4. RTK ───
rtk_is_correct() {
  command -v rtk &>/dev/null || return 1
  rtk gain &>/dev/null 2>&1
}

if rtk_is_correct; then
  ok "RTK already installed: $(rtk --version 2>/dev/null)"
else
  if command -v rtk &>/dev/null; then
    warn "Wrong 'rtk' detected (Rust Toolkit, not Rust Token Killer)"
    cargo uninstall rtk 2>/dev/null || rm -f "$(command -v rtk)"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if command -v cargo &>/dev/null; then
      info "[dry-run] Would install rtk from https://github.com/rtk-ai/rtk via cargo"
    else
      info "[dry-run] Would download rtk binary from https://github.com/rtk-ai/rtk/releases"
    fi
  else
    if command -v cargo &>/dev/null; then
      cargo install --git https://github.com/rtk-ai/rtk -q 2>/dev/null && ok "RTK via cargo" || warn "RTK cargo failed"
    else
      curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh \
        && ok "RTK installed via install.sh" || warn "RTK install.sh failed"
    fi
  fi
fi

# ── 5. Graph MCPs — code-review-graph + graphify ───
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would install code-review-graph via pip3"
  info "[dry-run] Would install graphifyy via pip3"
else
  pip3 install code-review-graph -q 2>/dev/null && ok "code-review-graph installed" || warn "code-review-graph install failed"
  pip3 install graphifyy -q 2>/dev/null && ok "graphifyy installed" || warn "graphifyy install failed"
fi

# ── 6. auto-init plugin ───
# (OpenMemory MCP removed — replaced by file-based ./NOTES.md per-project)
mkdir -p "$PLUGIN_DIR"
AUTOINIT_SRC="$PLUGIN_DIR/auto-init.ts"
AUTOINIT_BAK="$PLUGIN_DIR/auto-init.ts.bak_$TS"
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would write auto-init.ts to $AUTOINIT_SRC"
else
  if [[ -f "$AUTOINIT_BAK" ]]; then
    mv "$AUTOINIT_BAK" "$AUTOINIT_SRC"
    ok "auto-init.ts restored (existing user plugin preserved)"
  elif [[ ! -f "$AUTOINIT_SRC" ]]; then
    cat > "$AUTOINIT_SRC" << 'TS'
import type { Plugin } from "@opencode-ai/plugin"
export const AutoInit: Plugin = async ({ client }) => ({
  event: async ({ event }) => {
    const sid = (event as any).session_id
    if (!sid || event.type !== "session.created") return
    await client.session.prompt({
      path: { id: sid },
      body: { parts: [{ type: "text", text:
        "[auto-init] Silently: 1) read ./NOTES.md if it exists 2) confirm code-review-graph indexed 3) activate token-saver mode. Then await task."
      }]}
    })
  },
  "experimental.chat.system.transform": async (_input, output) => {
    output.system.push(`<global-token-rules>
- Use code-review-graph MCP for all symbol lookups and searches
- Read ./NOTES.md (project decision log) before each new task if it exists
- Output code as unified diffs, not full file rewrites
- Keep responses terse
- Append decisions to ./NOTES.md after each task
</global-token-rules>`)
  },
  "experimental.session.compacting": async (_input, output) => {
    output.context.push("<preserved>token-saver mode active; use MCP tools; output diffs only</preserved>")
  }
})
TS
    ok "auto-init.ts written"
  fi
fi

# ── 7. AGENTS.md ───
AGENTS_BAK="$AGENTS_MD.bak_$TS"
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would write AGENTS.md to $AGENTS_MD"
else
  if [[ -f "$AGENTS_BAK" ]]; then
    mv "$AGENTS_BAK" "$AGENTS_MD"
    ok "AGENTS.md restored (existing user rules preserved)"
  elif [[ ! -f "$AGENTS_MD" ]]; then
    cat > "$AGENTS_MD" << 'AGENTS'
# Global OpenCode Rules — Token Optimization
## Tool Priority
1. code-review-graph MCP before any grep/file read
2. Read ./NOTES.md before each new task (if it exists)
3. Output diffs, not full rewrites
4. Append decision entry to ./NOTES.md after each task (use `devin-note` helper if available)
## Output Rules
- Be terse. No padding. One sentence per point. Diffs only.
AGENTS
    ok "AGENTS.md written"
  fi
fi

# ── 8. Full opencode.jsonc ───
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would write opencode.jsonc to $CONFIG_FILE"
else
  cat > "$CONFIG_FILE" << 'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    "@tarquinen/opencode-dcp",
    "@zenobius/opencode-skillful",
    "opencode-conductor",
    "opencode-tokenscope",
    "opencode-token-monitor",
    ["opencode-lcm", {
      "interop": {
        "neverOverrideCompactionPrompt": true
      },
      "automaticRetrieval": {
        "enabled": true,
        "scopeOrder": ["session", "root"],
        "scopeBudgets": {
          "session": 16,
          "root": 12
        }
      },
      "retention": {
        "staleSessionDays": 90,
        "deletedSessionDays": 30,
        "orphanBlobDays": 14
      }
    }]
  ],
  "instructions": ["node_modules/@tarquinen/opencode-dcp/instructions/dcp.md"],
  "mcp": {
    "code-review-graph": {
      "type": "local",
      "enabled": true,
      "command": ["code-review-graph", "mcp"]
    }
  }
}
JSON
  ok "opencode.jsonc (optimized) written"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] Would append OpenCode env vars to $SHELL_RC"
else
  append_if_missing "$SHELL_RC" "export OPENCODE_DCP_STRATEGY=smart"
  append_if_missing "$SHELL_RC" "export OPENCODE_MAX_CONTEXT_TOKENS=8000"
  ok "Optimizer stack fully installed"
fi

# ════════════════════════════════════════════════════════════
step "PHASE 3 — Optimized benchmark (optimizer ON)"
# ════════════════════════════════════════════════════════════

if [[ "$SKIP_OPTIMIZED" -eq 1 ]]; then
  info "Skipping optimized (--skip-optimized)"
else
  PHASE="optimized"
  info "Running optimized tasks against: $PROJECT_DIR"
  cd "$PROJECT_DIR"

  for task_id in "${TASK_ORDER[@]}"; do
    prompt="${TASKS[$task_id]}"
    info "Optimized › $task_id: $prompt"

    T_START=$(date +%s)
    run_task "$prompt" 120
    T_END=$(date +%s)
    DURATION=$(( T_END - T_START ))

    read -r IN_TOK OUT_TOK CACHE_TOK TOTAL_TOK <<< "$(get_last_session_tokens)"

    echo "${task_id},optimized,${IN_TOK},${OUT_TOK},${CACHE_TOK},${TOTAL_TOK},${DURATION}" >> "$RESULTS_CSV"
    ok "$task_id optimized: ${TOTAL_TOK} total tokens in ${DURATION}s"
    sleep 2
  done

  ok "Optimized phase complete"
fi

# ════════════════════════════════════════════════════════════
step "PHASE 4 — Comparison report"
# ════════════════════════════════════════════════════════════

python3 << PYREPORT
import csv, os, json, sys

results_file = "$RESULTS_CSV"
json_file = "$RESULTS_JSON"

if not os.path.isfile(results_file):
    print("No results CSV found — nothing to report.")
    sys.exit(0)

rows = {}
with open(results_file) as f:
    for row in csv.DictReader(f):
        key = row["task"]
        rows.setdefault(key, {})[row["phase"]] = row

labels = {
    "task1": "Symbol search",
    "task2": "Dependency scan",
    "task3": "File edit (diff)",
    "task4": "Explanation query",
    "task5": "Multi-file analysis",
}

print()
print("=" * 72)
print("  OpenCode Token Benchmark — Before vs After Optimizer")
print("=" * 72)
print(f"  {'Task':<28} {'Baseline':>10} {'Optimized':>10} {'Saved':>8} {'%':>6}")
print("-" * 72)

total_base = 0; total_opt = 0
report = {"tasks": [], "summary": {}}

for task_id in ["task1","task2","task3","task4","task5"]:
    label = labels.get(task_id, task_id)
    b = rows.get(task_id, {}).get("baseline", {})
    o = rows.get(task_id, {}).get("optimized", {})
    bt = int(b.get("total_tokens", 0) or 0)
    ot = int(o.get("total_tokens", 0) or 0)
    saved = bt - ot
    pct = f"-{100*saved//bt}%" if bt > 0 else "N/A"
    total_base += bt; total_opt += ot
    print(f"  {label:<28} {bt:>10,} {ot:>10,} {saved:>8,} {pct:>6}")
    report["tasks"].append({
        "task": task_id, "label": label,
        "baseline": bt, "optimized": ot,
        "saved": saved, "percent": pct
    })

print("-" * 72)
total_saved = total_base - total_opt
total_pct = f"-{100*total_saved//total_base}%" if total_base > 0 else "N/A"
print(f"  {'TOTAL':<28} {total_base:>10,} {total_opt:>10,} {total_saved:>8,} {total_pct:>6}")
print("=" * 72)

report["summary"] = {
    "baseline": total_base, "optimized": total_opt,
    "saved": total_saved, "percent": total_pct
}
with open(json_file, "w") as jf:
    json.dump(report, jf, indent=2)

print(f"\n  CSV results:   {results_file}")
print(f"  JSON report:   {json_file}")
print(f"  Session logs:  ccusage session --last 10")
print(f"  Dashboard:     npx vibeusage")
print()
PYREPORT

# ─── Final summary ────────────────────────────────────────────
PHASE="done"
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  All done. Optimizer is now active globally.${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "${CYAN}  Useful commands going forward:${RESET}"
echo -e "  ${BOLD}opencode${RESET}                     Start optimized session (auto-runs everything)"
echo -e "  ${BOLD}ccusage daily${RESET}                Today's token + cost breakdown"
echo -e "  ${BOLD}ccusage session --last 10${RESET}    Last 10 sessions with totals"
echo -e "  ${BOLD}npx vibeusage${RESET}                Live dashboard"
echo -e "  ${BOLD}cat $RESULTS_CSV${RESET}  Raw CSV results"
echo -e "  ${BOLD}cat $RESULTS_JSON${RESET}  JSON summary"
echo ""
echo -e "  Re-run this script anytime to re-benchmark or update plugins."
echo -e "  Skip phases:  ${BOLD}$0 --skip-baseline --skip-optimized${RESET}"
echo ""
