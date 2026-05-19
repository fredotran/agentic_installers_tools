# Agentic Coding Tools

> AI-coding stack installer and token optimization suite for OpenCode.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [What Gets Installed](#what-gets-installed)
- [How the Stack Works Together](#how-the-stack-works-together)
- [Prompting for Token Reduction](#prompting-for-token-reduction)
- [Scripts](#scripts)
- [Global Rules Installer](#global-rules-installer)
- [Configuration](#configuration)

---

## Overview

This folder contains installers and setup scripts for an AI-assisted coding stack built around [OpenCode](https://opencode.ai/). The centerpiece is `setup-token-optimizer.sh`, which installs a collection of plugins, MCP servers, and global rules designed to minimize LLM token usage while maximizing context quality — and syncs the same strict rules to **all AI tools** on this system (OpenCode, Devin, Windsurf, Cascade).

The old standalone `setup-global-token-rules.sh` is now a **deprecated wrapper** that delegates to `setup-token-optimizer.sh`.

---

## Quick Start

```bash
# Install everything (interactive)
bash Agentic_Coding_Tools/install.sh

# Or install only the token optimizer stack
bash Agentic_Coding_Tools/scripts/setup-token-optimizer.sh

# Dry-run to preview changes
bash Agentic_Coding_Tools/scripts/setup-token-optimizer.sh --dry-run

# Or use the deprecated wrapper (delegates to setup-token-optimizer.sh)
bash Agentic_Coding_Tools/scripts/setup-global-token-rules.sh
```

After installation, start OpenCode:

```bash
source ~/.zshrc && opencode
```

Everything else is automatic.

---

## What Gets Installed

| Component | Package | Purpose |
|-----------|---------|---------|
| **DCP** | `@tarquinen/opencode-dcp` | Dynamic Context Pruning — silently drops obsolete tool outputs before every LLM call |
| **Skillful** | `@zenobius/opencode-skillful` | Lazy skill loading — loads relevant skills on demand |
| **Conductor** | `opencode-conductor-plugin` | Lifecycle scoping — manages session orchestration |
| **RTK** | `rtk` (from `rtk-ai/rtk`) | Rust Token Killer — compresses CLI output before it reaches the LLM |
| **code-review-graph** | `code-review-graph` (PyPI) | Tree-sitter symbol search, blast-radius analysis, dependency graph |
| **graphify** | `graphifyy` (PyPI) | Knowledge graph from code, docs, PDFs, images |
| **auto-init.ts** | Custom plugin | Fires on every session start to build graphs, activate token-saver |
| **AGENTS.md** | Global rules | Injected every session — enforces MCP-first, diff-only, terse output |

All configuration lands in `~/.config/opencode/`, and environment variables are appended to your shell RC file (`.zshrc` or `.bashrc`).

---

## How the Stack Works Together

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         YOUR PROMPT                                          │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
              ┌─────────────────────┴─────────────────────┐
              │                                           │
              ▼                                           ▼
┌──────────────────────────┐                 ┌──────────────────────────┐
│  1. auto-init.ts plugin  │                 │  2. AGENTS.md rules      │
│  (fires automatically)   │                 │  (injected every turn)   │
│                          │                 │                          │
│  • code-review-graph     │                 │  • Use code-review-graph │
│    → builds graph if     │                 │    before any grep/read  │
│      needed              │                 │  • Output diffs only     │
│  • token-saver mode      │                 │  • Store decisions       │
│                          │                 │    after each edit       │
│                          │                 │  • Be terse, no fluff    │
└──────────┬───────────────┘                 └──────────┬───────────────┘
           │                                              │
           └──────────────────┬───────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  3. DCP Plugin (@tarquinen/opencode-dcp)                                    │
│  Silently prunes context before every LLM call                              │
│  • Keeps: active_file, recent_errors                                        │
│  • Drops: old_history, debug_logs                                           │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  4. RTK (Rust Token Killer)                                                 │
│  Compresses shell command output before it reaches the LLM                  │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  5. MCP Tools (the heavy lifters)                                           │
│                                                                             │
│  code-review-graph  →  "Where is this used?"                                │
│  graphify           →  "Explain this codebase"                              │
│  NOTES.md           →  "What did I decide last time?"                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Automatic Session Lifecycle

| When | What happens |
|------|-------------|
| **Session start** | `code-review-graph build` (if needed) → token-saver mode activated |
| **After each task** | Decisions appended to project `NOTES.md` |
| **On context compaction** | `preserved-state` block carries working directory + rules forward |
| **Before every LLM call** | DCP prunes old history, keeps active file + recent errors |

---

## Prompting for Token Reduction

### 1. Finding where something is defined / used

**Bad (burns tokens):**
> "Search the codebase for the function `calculate_distance` and tell me where it's defined and all the files that call it."

**Good (uses graph, saves ~10x tokens):**
> "Use `code-review-graph` to find the definition of `calculate_distance` and its blast radius. Report only the impacted files — don't read them yet."

Why: The graph returns a structured list of impacted files (usually 3-15) instead of grepping the entire repo and reading every match.

---

### 2. Refactoring a function

**Bad (burns tokens):**
> "I want to refactor the `LocalizationFilter` class. Please read the full file, then refactor it."

**Good (uses graph + diffs):**
> "Use `code-review-graph` to find the blast radius of `LocalizationFilter`. Then output a unified diff (udiff) of the required changes. Do not show the full file contents."

Why: The graph tells the agent exactly which callers need updating. The udiff rule prevents dumping entire files back.

---

### 3. Picking up work from a previous session

**Bad (burns tokens):**
> "I was working on sensor fusion yesterday. Can you remind me what I was doing and where I left off?"

**Good (reads NOTES.md first):**
> "Read `./NOTES.md` for any decisions about sensor fusion in this directory, then tell me the key decisions and open tasks."

Why: `NOTES.md` is an append-only decision log that persists across sessions.

---

### 4. Understanding a large codebase

**Bad (burns tokens):**
> "Explain how this project works. Read the main files and give me a summary."

**Good (uses graphify):**
> "Run `/graphify` on this directory. Then query the graph: what are the god nodes, surprising connections, and suggested questions?"

Why: `graphify` pre-builds a knowledge graph. Querying it returns a compact summary instead of reading dozens of files. On a 52-file corpus this is **71x fewer tokens**.

---

### 5. After making changes — persist context

**Bad (burns tokens on next session):**
> (nothing — you just leave)

**Good (automatic):**
> After every task completion, decisions are silently appended to `NOTES.md`.

Why: The append-only log ensures the *why* is remembered without manual prompts.

---

### 6. Debugging an error

**Bad (burns tokens):**
> "I got this error: [paste 200 lines of stack trace]. Fix it."

**Good (DCP keeps the error, graph finds the cause):**
> "Use `code-review-graph` to trace the call chain from the entry point in the stack trace. Focus only on the blast radius. Output a minimal fix as a udiff."

Why: DCP automatically preserves `recent_errors` in context. The graph narrows the search to only relevant code paths.

---

### One-liner to reinforce token-saving behavior

If you want to be explicit in a prompt, prefix with:

> "Use the graph tools first, diffs only, store decisions to memory."

Everything else is handled automatically by the plugin and AGENTS.md.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | Full installer: opencode CLI, oh-my-openagent, token optimizers, obra/superpowers |
| `scripts/setup-token-optimizer.sh` | Installs DCP, Skillful, Conductor, RTK, MCP servers, global rules, and syncs rules to all AI tools |
| `scripts/setup-global-token-rules.sh` | **Deprecated wrapper** — delegates to `setup-token-optimizer.sh` |
| `scripts/backup-restore-ai-configs.sh` | Backup and restore AI tool configs across machines |
| `scripts/run-benchmark.sh` | Benchmarks token usage before/after optimizer stack |
| `AGENTS.md` (repo root) | Project-specific rules injected every session |

### setup-token-optimizer.sh Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview all changes without applying them |

---

## Global Rules Installer

`setup-token-optimizer.sh` (steps 7–10) pushes strict token-saving rules to **every AI tool on your system** after installing the stack. The old standalone `setup-global-token-rules.sh` is now a **deprecated wrapper** that delegates to `setup-token-optimizer.sh`.

### What it covers

| Tool | File updated | What happens |
|------|-------------|--------------|
| **OpenCode** | `~/.config/opencode/AGENTS.md` | Strict 10-rule AGENTS.md injected every session |
| **Devin** | `~/.config/devin/skills/token-optimizer/SKILL.md` | Global skill invoked via `skill` tool or AGENTS.md table |
| **Windsurf** | `~/.codeium/windsurf/skills/token-optimizer/SKILL.md` | Global skill auto-loaded via `auto_load_skills` |
| **Cascade** | `~/.codeium/windsurf/memories/global_rules.md` | `token-optimizer` added to `auto_load_skills` |

### Usage

```bash
# Preview what it will do
bash Agentic_Coding_Tools/scripts/setup-token-optimizer.sh --dry-run

# Apply for real (backs up existing files automatically)
bash Agentic_Coding_Tools/scripts/setup-token-optimizer.sh
```

### Key features

- **Self-contained** — all content embedded, no network calls
- **Backs up** existing files with timestamps before overwriting
- **Idempotent** — safe to run multiple times; skips if already present
- **Dry-run** support for preview
- **Deprecated wrapper** — `setup-global-token-rules.sh` still works but delegates to `setup-token-optimizer.sh`

---

## Backup and Restore

The **`backup-restore-ai-configs.sh`** script provides a single cross-tool backup mechanism for all AI configurations.

### What it covers

| Tool | Backed up |
|------|-----------|
| **OpenCode** | `~/.config/opencode/` — config, plugins, skills, AGENTS.md |
| **Oh-My-OpenAgent** | `~/.oh-my-openagent/` — plugins, agents, templates |
| **Devin** | `~/.config/devin/` — skills, config, templates |
| **Windsurf / Codeium** | `~/.codeium/windsurf/` — skills, memories, global rules |

### Usage

```bash
# Save configs to a tar.gz archive
bash Agentic_Coding_Tools/scripts/backup-restore-ai-configs.sh save --dest ./my-backup.tar.gz

# Save as a plain directory
bash Agentic_Coding_Tools/scripts/backup-restore-ai-configs.sh save --dest ./my-backup --format dir

# List what would be backed up (dry-run)
bash Agentic_Coding_Tools/scripts/backup-restore-ai-configs.sh save --dry-run

# Restore configs from a backup
bash Agentic_Coding_Tools/scripts/backup-restore-ai-configs.sh restore --from ./my-backup.tar.gz

# Non-interactive restore
bash Agentic_Coding_Tools/scripts/backup-restore-ai-configs.sh restore --from ./my-backup.tar.gz --yes
```

### Key features

- **Self-contained** — single script, no dependencies beyond standard GNU utilities
- **Safe** — backs up existing files with timestamps before overwriting on restore
- **Dry-run** support for preview
- **Idempotent** — safe to run multiple times

---

## Configuration

After running the setup script, your OpenCode configuration lives in:

```
~/.config/opencode/
├── opencode.jsonc          # Plugin list, MCP servers, instructions
├── AGENTS.md               # Global rules (injected every session)
├── skills/
│   └── token-saver.md      # Token-saver skill definition
└── plugin/
    └── auto-init.ts        # Session lifecycle automation
```

### MCP Servers Configured

- **`code-review-graph`** — `code-review-graph mcp` (stdio)
- **`graphify`** — `graphify --mcp` (stdio)

### Project Memory

- **`AGENTS.md`** (repo root) — project-specific rules, auto-injected every session
- **`NOTES.md`** (repo root) — append-only decision log; the agent appends entries after every task

### Environment Variables

Added to your shell RC:

```bash
export OPENCODE_DCP_STRATEGY=smart
export OPENCODE_MAX_CONTEXT_TOKENS=8000
```

---

## Changes Since Initial Release

### Installer (`install.sh`)
- **Preserves existing `oh-my-openagent.json`** — Will not overwrite your rich agent/category config unless `--force` is passed
- **Handles local plugins** — Detects existing `file:///.../oh-my-opendevin` plugins and does not add conflicting npm references
- **Fixed package name** — `oh-my-openagent@latest` (was `oh-my-opencode`)
- **Updated template** — Matches your current agent routing (sisyphus, hephaestus, oracle, librarian, explore, multimodal-looker, prometheus, metis, momus, atlas, sisyphus-junior)

### Token Optimizer (`setup-token-optimizer.sh`)
- **Respects existing plugins** — Detects whether you have `auto-init.js` or `auto-init.ts` and preserves existing files
- **Syncs AGENTS.md** — Full rule set is consistent across all scripts
- **Package name consistency** — Uses `code-review-graph` (not `better-code-review-graph`)
- **Adds `graphify` MCP** — Both graph tools are now wired in generated configs
- **Merged global rules** — Now includes Devin skill, Windsurf skill, and `global_rules.md` updates (was in separate `setup-global-token-rules.sh`)

### Benchmark (`run-benchmark.sh`)
- **Updated plugin names** — Uses `@tarquinen/opencode-dcp` and `@zenobius/opencode-skillful`
- **Added `graphify` MCP** — Both graph tools benchmarked together
- **Removed hardcoded Python 3.13** — Uses system Python for `code-review-graph`

### Backup & Restore (`backup-restore-ai-configs.sh`)
- **More complete coverage** — Backs up `.mcp.json`, `settings.json`, `config.json`, `.gitignore`, `model_list`, and the `oh-my-opendevin` local plugin
- **Handles `ohmyopendevin`** — New backup category for your local plugin fork

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `pip3 install` fails with "externally-managed-environment" | The script adds `--break-system-packages` automatically |
| `bun install -q` dumps help text | Fixed — uses `--silent` instead of `-q` |
| Package not found on npm | Script validates existence via `npm view` before installing |
| Python 3.13 required for a package | `better-code-review-graph` was replaced with `code-review-graph` (works on 3.10+) |
| Graph not indexed | The auto-init plugin builds it on first session start |

---

For questions or issues, open a merge request or contact the maintainers.
