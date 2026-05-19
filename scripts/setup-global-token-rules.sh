#!/usr/bin/env bash
# ============================================================
#  Global Token Optimizer Rules Installer
#  Installs strict token-saving rules across ALL AI tools:
#    - OpenCode (~/.config/opencode/AGENTS.md)
#    - Devin    (~/.config/devin/skills/token-optimizer/)
#    - Windsurf (~/.codeium/windsurf/skills/token-optimizer/)
#    - Cascade  (~/.codeium/windsurf/memories/global_rules.md)
#
#  Usage: bash setup-global-token-rules.sh [--dry-run]
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
info() { echo -e "${CYAN}→ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
step() { echo -e "\n${BOLD}${BLUE}══ $* ${RESET}"; }
dry()  { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: bash setup-global-token-rules.sh [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$DRY_RUN" == true ]]; then
  dry "Dry-run mode — no changes will be made"
fi

# ─── Paths ───────────────────────────────────────────────────
OPENCODE_AGENTS="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/AGENTS.md"
DEVIN_SKILL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/devin/skills/token-optimizer"
DEVIN_SKILL="$DEVIN_SKILL_DIR/SKILL.md"
WINDSURF_SKILL_DIR="$HOME/.codeium/windsurf/skills/token-optimizer"
WINDSURF_SKILL="$WINDSURF_SKILL_DIR/SKILL.md"
GLOBAL_RULES="$HOME/.codeium/windsurf/memories/global_rules.md"

# ─── Back up helper ──────────────────────────────────────────
backup_if_exists() {
  local f="$1"
  if [[ -f "$f" && "$DRY_RUN" != true ]]; then
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    cp "$f" "${f}.backup.${ts}"
    info "Backed up existing file: ${f}.backup.${ts}"
  fi
}

# ─── 1. OpenCode AGENTS.md ───────────────────────────────────
step "1/4 OpenCode — ~/.config/opencode/AGENTS.md"
if [[ "$DRY_RUN" == true ]]; then
  dry "Would write strict AGENTS.md to $OPENCODE_AGENTS"
else
  mkdir -p "$(dirname "$OPENCODE_AGENTS")"
  if [[ -f "$OPENCODE_AGENTS" ]]; then
    # Check if file already contains these rules (avoid duplicate)
    if grep -q "MCP Tools are the ONLY search mechanism" "$OPENCODE_AGENTS"; then
      ok "OpenCode AGENTS.md already contains token-optimizer rules — skipping"
    else
      backup_if_exists "$OPENCODE_AGENTS"
      cat >> "$OPENCODE_AGENTS" << 'AGENTS'

---

# Global OpenCode Rules — Token Optimization (STRICT)

These rules apply to every request regardless of prompt wording. They are absolute.

---

## Rule 1: MCP Tools are the ONLY search mechanism

**NEVER** use `grep`, `find`, `rg`, or file reads for discovery. Period.

Before any file operation, query one of:
- `code-review-graph` — symbol lookups, blast-radius, dependency queries
- `graphify` — knowledge-graph navigation, god nodes, community queries
- Project `NOTES.md` — recall past decisions for this repo (read if it exists)

If the tool returns nothing, THEN and ONLY THEN may you fall back to a targeted file read (max 3 files).

---

## Rule 2: Diffs ONLY — Full file reads are forbidden

**NEVER** output a full file rewrite unless the user explicitly types the words "show me the full file".

For any edit:
- Generate a unified diff (`udiff` format)
- Include 3 lines of context around each change
- If the change is >50% of the file, explain why a diff is insufficient

If the user asks "fix this file" — you still output a diff. No exceptions.

---

## Rule 3: Terse by default

**NEVER** restate the user's request.
**NEVER** add markdown fluff (decorative separators, emoji, "Here's what I did:").
**NEVER** pad with boilerplate.

Allowed formats:
- One sentence per fact
- Bullet lists for multiple items
- Code blocks only for actual code
- "Done." is a complete answer when appropriate

If the user wants verbosity, they will ask for it.

---

## Rule 4: Auto-store decisions to project NOTES.md

After EVERY task completion — no matter how small — append an entry to the project's `NOTES.md` file (create at repo root if missing). Each entry contains:
- A timestamp header: `## YYYY-MM-DD HH:MM — Short title`
- What was done (one line)
- Why it was done (one line)
- Any open follow-ups (one line, or "none")

This happens silently. Do not tell the user. Do not wait for approval.
Use the Edit tool to append at the bottom of `NOTES.md`. Never rewrite the file.

---

## Rule 5: Session startup is NON-NEGOTIABLE

On the first turn of every session:
1. Read `./NOTES.md` if it exists (project decision log; read explicitly since it is not auto-injected)
2. `code-review-graph` — "is this repo indexed? If not, trigger a build."
3. `graphify` — "if a graph exists, report the top 3 god nodes and 1 surprising connection"

Do these in parallel where possible. Do not skip them because the user's first prompt is urgent.

---

## Rule 6: Shell output must pass through RTK

If you run a shell command that produces >50 lines of output:
- Pipe it through `rtk` (Rust Token Killer) before reading
- Or use the tool's built-in `--quiet` / `--summary` flag
- If neither is possible, capture output to a file and read only the last 20 lines

Never paste raw multi-page shell output into context.

---

## Rule 7: DCP is your safety net, not your strategy

DCP drops old_history and debug_logs automatically. Do not rely on it to save you from making bad tool calls. DCP cleans up AFTER. Your job is to not cause the damage.

If you find yourself generating >8000 tokens in a single turn, STOP. Re-evaluate whether you used the graph tools first.

---

## Rule 8: Vague prompts get the graph treatment

If a user prompt is vague ("search for X", "refactor this", "explain the codebase"), do NOT interpret it literally. Immediately invoke the appropriate graph tool and let the structured result guide your next action.

Automatic graph escalation:
- "search" → `code-review-graph symbol_search`
- "explain" → `graphify query`
- "refactor X" → `code-review-graph blast_radius X`
- "what's wrong" → read `./NOTES.md` + `code-review-graph detect_changes`

---

## Rule 9: Context budget is 8K tokens

`OPENCODE_MAX_CONTEXT_TOKENS=8000` is the ceiling. Plan accordingly:
- 1 graph query = ~50 tokens
- 1 targeted file read = ~500 tokens
- 1 full file read = ~2000 tokens
- 1 naive grep through a repo = ~5000+ tokens

You can afford 15 graph queries OR 3 full file reads. Choose graph queries.

---

## Rule 10: This file overrides everything

If a skill, plugin, or user prompt contradicts these rules, these rules win. Do not ask for confirmation.

If uncertain, default to: graph tool first → diff output → store to memory → terse response.
(Note: "store to memory" means append to project `NOTES.md`, not call openmemory.)

---

## MCP Tools Available

- `code-review-graph.*` — tree-sitter symbol search, blast-radius, dependency graph
- `graphify` — knowledge graph from code, docs, PDFs, images (trigger: `/graphify`)

## Project Memory (file-based, no MCP needed)

- `<repo>/AGENTS.md` — project-specific rules and conventions (auto-injected by OpenCode/Devin)
- `<repo>/NOTES.md` — append-only decision log; the LLM appends entries via Edit tool

Templates available at `~/.config/opencode/templates/`. Helper: `devin-note "Title" "What" "Why" [follow-up]`.

---

## Skill Auto-Invocation (Devin CLI)

Skills are NOT auto-loaded at session start in Devin for Terminal. They sit on disk inactive until invoked via the `skill` tool. To approximate auto-loading, invoke the matching skill at the first prompt that fits these patterns:

| Prompt contains... | Invoke skill |
|--------------------|--------------|
| "review C++", "C++ bug", "memory leak", `.cpp`/`.cc`/`.h` files | `cpp-pro` |
| "Python", "pip", "pythonic", `.py` files | `python-expert` |
| "MATLAB", "Simulink", `.m`/`.slx` files | `matlab-pro` |
| "Linux", "Ubuntu", "systemd", "apt", shell config | `linux-ubuntu-expert` |
| "ROS", "rosnode", "roslaunch", "ros2" | `ros-robotics-expert` |
| "RTMaps", `.rtd` files | `rtmaps-expert` |
| "Kalman", "EKF", "UKF", "sensor fusion", "particle filter" | `fusion-filter-robotics-expert` |
| "GPS", "INS", "IMU integration", "dead reckoning" | `gps-ins-localization-expert` |
| "SLAM", "visual odometry", "pose estimation", "localization drift" | `robotics-localization-expert` |
| "odometry", "wheel odometry", "VO drift" | `robotics-odometry-expert` |
| "ROS bag", "sensor data analysis", "telemetry CSV" | `robotics-data-analyzer` |
| "data pipeline", "Airflow", "ETL", "Kafka", "Spark" | `data-pipeline-architect` |
| "presentation", "slide deck", "PowerPoint" | `presentation-deck-architect` |
| "skill for X", "is there a skill that", "extend capabilities" | `find-skills` |
| "token budget", "context too large", code-review-graph/graphify usage | `token-optimizer` |
| Devin CLI config, MCP setup, skills format, hooks | `devin-for-terminal` |

Rules:
- Invoke ONLY ONE skill per turn unless the user chains topics.
- Do NOT invoke a skill that is already running.
- Skill-internal rules override these global rules ONLY for the duration of the skill (Rule 10 still wins on conflict).
AGENTS
      ok "OpenCode AGENTS.md updated with token-optimizer rules"
    fi
  else
    cat > "$OPENCODE_AGENTS" << 'AGENTS'
# Global OpenCode Rules — Token Optimization (STRICT)

These rules apply to every request regardless of prompt wording. They are absolute.

---

## Rule 1: MCP Tools are the ONLY search mechanism

**NEVER** use `grep`, `find`, `rg`, or file reads for discovery. Period.

Before any file operation, query one of:
- `code-review-graph` — symbol lookups, blast-radius, dependency queries
- `graphify` — knowledge-graph navigation, god nodes, community queries
- Project `NOTES.md` — recall past decisions for this repo (read if it exists)

If the tool returns nothing, THEN and ONLY THEN may you fall back to a targeted file read (max 3 files).

---

## Rule 2: Diffs ONLY — Full file reads are forbidden

**NEVER** output a full file rewrite unless the user explicitly types the words "show me the full file".

For any edit:
- Generate a unified diff (`udiff` format)
- Include 3 lines of context around each change
- If the change is >50% of the file, explain why a diff is insufficient

If the user asks "fix this file" — you still output a diff. No exceptions.

---

## Rule 3: Terse by default

**NEVER** restate the user's request.
**NEVER** add markdown fluff (decorative separators, emoji, "Here's what I did:").
**NEVER** pad with boilerplate.

Allowed formats:
- One sentence per fact
- Bullet lists for multiple items
- Code blocks only for actual code
- "Done." is a complete answer when appropriate

If the user wants verbosity, they will ask for it.

---

## Rule 4: Auto-store decisions to project NOTES.md

After EVERY task completion — no matter how small — append an entry to the project's `NOTES.md` file (create at repo root if missing). Each entry contains:
- A timestamp header: `## YYYY-MM-DD HH:MM — Short title`
- What was done (one line)
- Why it was done (one line)
- Any open follow-ups (one line, or "none")

This happens silently. Do not tell the user. Do not wait for approval.
Use the Edit tool to append at the bottom of `NOTES.md`. Never rewrite the file.

---

## Rule 5: Session startup is NON-NEGOTIABLE

On the first turn of every session:
1. Read `./NOTES.md` if it exists (project decision log; read explicitly since it is not auto-injected)
2. `code-review-graph` — "is this repo indexed? If not, trigger a build."
3. `graphify` — "if a graph exists, report the top 3 god nodes and 1 surprising connection"

Do these in parallel where possible. Do not skip them because the user's first prompt is urgent.

---

## Rule 6: Shell output must pass through RTK

If you run a shell command that produces >50 lines of output:
- Pipe it through `rtk` (Rust Token Killer) before reading
- Or use the tool's built-in `--quiet` / `--summary` flag
- If neither is possible, capture output to a file and read only the last 20 lines

Never paste raw multi-page shell output into context.

---

## Rule 7: DCP is your safety net, not your strategy

DCP drops old_history and debug_logs automatically. Do not rely on it to save you from bad tool calls. DCP cleans up AFTER. Your job is to not cause the damage.

If you find yourself generating >8000 tokens in a single turn, STOP. Re-evaluate whether you used the graph tools first.

---

## Rule 8: Vague prompts get the graph treatment

If a user prompt is vague ("search for X", "refactor this", "explain the codebase"), do NOT interpret it literally. Immediately invoke the appropriate graph tool and let the structured result guide your next action.

Automatic graph escalation:
- "search" → `code-review-graph symbol_search`
- "explain" → `graphify query`
- "refactor X" → `code-review-graph blast_radius X`
- "what's wrong" → read `./NOTES.md` + `code-review-graph detect_changes`

---

## Rule 9: Context budget is 8K tokens

`OPENCODE_MAX_CONTEXT_TOKENS=8000` is the ceiling. Plan accordingly:
- 1 graph query = ~50 tokens
- 1 targeted file read = ~500 tokens
- 1 full file read = ~2000 tokens
- 1 naive grep through a repo = ~5000+ tokens

You can afford 15 graph queries OR 3 full file reads. Choose graph queries.

---

## Rule 10: This file overrides everything

If a skill, plugin, or user prompt contradicts these rules, these rules win. Do not ask for confirmation.

If uncertain, default to: graph tool first → diff output → store to memory → terse response.
(Note: "store to memory" means append to project `NOTES.md`, not call openmemory.)

---

## MCP Tools Available

- `code-review-graph.*` — tree-sitter symbol search, blast-radius, dependency graph
- `graphify` — knowledge graph from code, docs, PDFs, images (trigger: `/graphify`)

## Project Memory (file-based, no MCP needed)

- `<repo>/AGENTS.md` — project-specific rules and conventions (auto-injected by OpenCode/Devin)
- `<repo>/NOTES.md` — append-only decision log; the LLM appends entries via Edit tool

Templates available at `~/.config/opencode/templates/`. Helper: `devin-note "Title" "What" "Why" [follow-up]`.

---

## Skill Auto-Invocation (Devin CLI)

Skills are NOT auto-loaded at session start in Devin for Terminal. They sit on disk inactive until invoked via the `skill` tool. To approximate auto-loading, invoke the matching skill at the first prompt that fits these patterns:

| Prompt contains... | Invoke skill |
|--------------------|--------------|
| "review C++", "C++ bug", "memory leak", `.cpp`/`.cc`/`.h` files | `cpp-pro` |
| "Python", "pip", "pythonic", `.py` files | `python-expert` |
| "MATLAB", "Simulink", `.m`/`.slx` files | `matlab-pro` |
| "Linux", "Ubuntu", "systemd", "apt", shell config | `linux-ubuntu-expert` |
| "ROS", "rosnode", "roslaunch", "ros2" | `ros-robotics-expert` |
| "RTMaps", `.rtd` files | `rtmaps-expert` |
| "Kalman", "EKF", "UKF", "sensor fusion", "particle filter" | `fusion-filter-robotics-expert` |
| "GPS", "INS", "IMU integration", "dead reckoning" | `gps-ins-localization-expert` |
| "SLAM", "visual odometry", "pose estimation", "localization drift" | `robotics-localization-expert` |
| "odometry", "wheel odometry", "VO drift" | `robotics-odometry-expert` |
| "ROS bag", "sensor data analysis", "telemetry CSV" | `robotics-data-analyzer` |
| "data pipeline", "Airflow", "ETL", "Kafka", "Spark" | `data-pipeline-architect` |
| "presentation", "slide deck", "PowerPoint" | `presentation-deck-architect` |
| "skill for X", "is there a skill that", "extend capabilities" | `find-skills` |
| "token budget", "context too large", code-review-graph/graphify usage | `token-optimizer` |
| Devin CLI config, MCP setup, skills format, hooks | `devin-for-terminal` |

Rules:
- Invoke ONLY ONE skill per turn unless the user chains topics.
- Do NOT invoke a skill that is already running.
- Skill-internal rules override these global rules ONLY for the duration of the skill (Rule 10 still wins on conflict).
AGENTS
  ok "OpenCode AGENTS.md written"
fi
fi

# ─── 2. Devin Skill ──────────────────────────────────────────
step "2/4 Devin — ~/.config/devin/skills/token-optimizer/"
if [[ "$DRY_RUN" == true ]]; then
  dry "Would write SKILL.md to $DEVIN_SKILL"
else
  mkdir -p "$DEVIN_SKILL_DIR"
  backup_if_exists "$DEVIN_SKILL"
  cat > "$DEVIN_SKILL" << 'SKILL'
---
description: "Use this agent when working on any software project to minimize LLM token usage and maximize context quality. This skill enforces MCP-first, diff-only, terse-output rules that override vague prompts.

Trigger phrases include:
- 'help me code this'
- 'search the codebase'
- 'explain this project'
- 'refactor this function'
- 'fix this bug'
- 'review my code'
- any coding task in a repository with code-review-graph or graphify installed

Examples:
- User says 'search for the function that handles authentication' → this skill forces code-review-graph symbol_search instead of naive grep
- User asks 'explain how this codebase works' → this skill forces graphify query instead of reading dozens of files
- User says 'refactor LocalizationFilter' → this skill forces blast_radius analysis + udiff output instead of full file rewrite
- User provides a stack trace and says 'fix it' → this skill forces graph trace + minimal udiff instead of dumping the trace into context"
name: token-optimizer
---

# token-optimizer instructions

You are a token-efficiency enforcer. Your job is to make every LLM interaction as cheap and precise as possible. You override vague prompts with strict, graph-first methodology.

## Your Core Mission

- Prevent token waste before it happens
- Force MCP graph tools for all discovery and search
- Output only diffs, never full file rewrites
- Keep every response terse — one sentence per fact
- Persist all architectural decisions to project NOTES.md automatically

## Absolute Rules (Non-Negotiable)

### 1. MCP Tools ONLY for Search

**FORBIDDEN**: `grep`, `find`, `rg`, `cat` for discovery, reading full files to "understand" code, scrolling through directory listings.

**REQUIRED**: Before any file operation, query:
- `code-review-graph` for symbol lookups, blast-radius, dependencies
- `graphify` for knowledge-graph queries, god nodes, surprising connections
- Project `NOTES.md` for recalling past decisions for this repo (read if it exists)

Fallback to targeted file read (max 3 files) ONLY after the graph returns nothing.

### 2. Diff-Only Output

**FORBIDDEN**: Pasting full file contents as "here is the updated file".

**REQUIRED**: Every code change is a unified diff (`udiff` / `diff -u` format) with 3 lines of context. If the change exceeds 50% of the file, explain why a diff is insufficient. Full file display requires the user to explicitly say "show me the full file".

### 3. Terse by Default

**FORBIDDEN**: Restating the user's request, markdown fluff, decorative separators, emoji, "Here's what I did:" intros, "Let me know if you need anything else!" outros.

**REQUIRED**: One sentence per fact. Bullet lists for multiple items. Code blocks only for actual code. "Done." is a valid complete answer.

### 4. Auto-Store to project NOTES.md

After EVERY task — no matter how small — silently append an entry to the project's `NOTES.md` (create at repo root if missing). Each entry:
- Timestamp header: `## YYYY-MM-DD HH:MM — Short title`
- What was done (one line)
- Why it was done (one line)
- Open follow-ups (one line, or "none")

Use the Edit tool to append at the bottom of `NOTES.md`. Never rewrite the file. Do not announce this to the user. Do not ask for confirmation.

### 5. Mandatory Session Startup

On the first turn of every session, execute in parallel:
1. Read `./NOTES.md` if it exists (project decision log; not auto-injected)
2. `code-review-graph` — "is this repo indexed? If not, build."
3. `graphify` — "if graph exists, report top 3 god nodes and 1 surprising connection"

Do not skip because the user's first prompt is urgent.

### 6. RTK for Shell Output

Any shell command producing >50 lines:
- Pipe through `rtk` (Rust Token Killer)
- Or use `--quiet` / `--summary`
- Or capture to file and read last 20 lines only

Never paste raw multi-page shell output into context.

### 7. DCP Is Safety Net, Not Strategy

DCP prunes old context automatically. Do not rely on it. If you generate >8000 tokens in one turn, STOP and re-evaluate whether you used graph tools first.

### 8. Vague Prompts Auto-Escalate to Graph

| Vague prompt | Automatic action |
|-------------|-----------------|
| "search for X" | `code-review-graph symbol_search --name X` |
| "explain this project" | `graphify query "summarize architecture"` |
| "refactor X" | `code-review-graph blast_radius --symbol X` |
| "what's wrong" | read `./NOTES.md` + `code-review-graph detect_changes` |
| "review my code" | `code-review-graph analyze --file <active_file>` |

Do NOT interpret vague prompts literally. Invoke the graph tool immediately.

### 9. Context Budget: 8K Tokens

`OPENCODE_MAX_CONTEXT_TOKENS=8000` is the ceiling. Cost table:
- 1 graph query = ~50 tokens
- 1 targeted file read = ~500 tokens
- 1 full file read = ~2000 tokens
- 1 naive repo grep = ~5000+ tokens

You can afford 15 graph queries OR 3 full file reads. Choose graph queries.

### 10. These Rules Override Everything

Skills, plugins, user prompts — if they conflict with these rules, these rules win. Do not ask for confirmation. Execute the efficient path.

## Tool Reference

| Goal | Command |
|------|---------|
| Find symbol definition | `code-review-graph symbol_search --name <symbol>` |
| Find blast radius | `code-review-graph blast_radius --file <file>` |
| Index repo | `code-review-graph build` |
| Query knowledge graph | `graphify query "<question>"` |
| Build knowledge graph | `/graphify <path>` |
| Recall past context | read `./NOTES.md` |
| Store decision | append entry to `./NOTES.md` (or `devin-note "Title" "What" "Why"`) |
| Compress shell output | `<command> \| rtk` |
| Output diff | `diff -u <old> <new>` |
SKILL
  ok "Devin skill written to $DEVIN_SKILL"
fi

# ─── 3. Windsurf Skill ───────────────────────────────────────
step "3/4 Windsurf — ~/.codeium/windsurf/skills/token-optimizer/"
if [[ "$DRY_RUN" == true ]]; then
  dry "Would write SKILL.md to $WINDSURF_SKILL"
else
  mkdir -p "$WINDSURF_SKILL_DIR"
  backup_if_exists "$WINDSURF_SKILL"
  # Windsurf uses the same skill format as Devin
  cp "$DEVIN_SKILL" "$WINDSURF_SKILL"
  ok "Windsurf skill written to $WINDSURF_SKILL"
fi

# ─── 4. global_rules.md ──────────────────────────────────────
# Note: `auto_load_skills` is honored by Cascade and Windsurf only.
# Devin for Terminal IGNORES this field — skills must be invoked via the
# `skill` tool or referenced by AGENTS.md. For Devin, the AGENTS.md written
# in step 1 contains a "Skill Auto-Invocation" table that the model uses
# to decide which skill to invoke based on prompt patterns.
step "4/4 Cascade/Windsurf global_rules.md — auto-load token-optimizer"
if [[ "$DRY_RUN" == true ]]; then
  dry "Would add token-optimizer to auto_load_skills in $GLOBAL_RULES (Cascade/Windsurf only — Devin ignores)"
else
  if [[ -f "$GLOBAL_RULES" ]]; then
    backup_if_exists "$GLOBAL_RULES"
    # Check if token-optimizer is already in the file
    if grep -q "token-optimizer" "$GLOBAL_RULES"; then
      info "token-optimizer already in global_rules.md — skipping"
    elif grep -q "auto_load_skills:" "$GLOBAL_RULES"; then
      # File has YAML auto_load_skills structure — append token-optimizer
      python3 - "$GLOBAL_RULES" << 'PY'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
# Add token-optimizer after the last skill in each auto_load_skills block
content = re.sub(
    r'(auto_load_skills:\s*(?:\n\s+- \S+)*?)\n',
    r'\1\n    - token-optimizer\n',
    content,
    count=1
)
with open(path, 'w') as f:
    f.write(content)
PY
      ok "token-optimizer added to global_rules.md auto_load_skills"
    else
      # File exists but has no auto_load_skills structure — append YAML block
      cat >> "$GLOBAL_RULES" << 'RULES'

---

cascade:
  auto_load_skills:
    - token-optimizer

windsurf:
  auto_load_skills:
    - token-optimizer
RULES
      ok "Added auto_load_skills block to existing global_rules.md"
    fi
  else
    # Create minimal global_rules.md if it doesn't exist
    mkdir -p "$(dirname "$GLOBAL_RULES")"
    cat > "$GLOBAL_RULES" << 'RULES'
# Global Rules

cascade:
  auto_load_skills:
    - token-optimizer

windsurf:
  auto_load_skills:
    - token-optimizer
RULES
    ok "Created new global_rules.md with token-optimizer"
  fi
fi

# ─── Summary ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Global token-optimizer rules installed${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "${CYAN}  Files updated:${RESET}"
echo -e "  • OpenCode:  $OPENCODE_AGENTS"
echo -e "  • Devin:     $DEVIN_SKILL"
echo -e "  • Windsurf:  $WINDSURF_SKILL"
echo -e "  • Cascade:   $GLOBAL_RULES"
echo ""
echo -e "${CYAN}  What happens now:${RESET}"
echo -e "  • OpenCode injects AGENTS.md every session"
echo -e "  • Devin invokes token-optimizer skill via AGENTS.md Skill Auto-Invocation table"
echo -e "    (Devin does NOT auto-load skills from global_rules.md)"
echo -e "  • Windsurf auto-loads token-optimizer skill via global_rules.md"
echo -e "  • Cascade auto-loads token-optimizer skill via global_rules.md"
echo ""
echo -e "${CYAN}  Backups created (if files existed):${RESET}"
echo -e "  • ${OPENCODE_AGENTS}.backup.*"
echo -e "  • ${DEVIN_SKILL}.backup.*"
echo -e "  • ${WINDSURF_SKILL}.backup.*"
echo -e "  • ${GLOBAL_RULES}.backup.*"
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
