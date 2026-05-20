## 2026-05-20 00:59 — Remove invalid top-level "dcp" key from opencode.jsonc

- Removed the `cfg["dcp"]` write block from `scripts/setup-token-optimizer.sh` and deleted the existing `"dcp"` object from `~/.config/opencode/opencode.jsonc`.
- OpenCode's config schema no longer recognizes the top-level `"dcp"` key; the `@tarquinen/opencode-dcp` plugin now handles DCP internally.
- none

## 2026-05-20 01:05 — Fix MCP server schema (add type/enabled keys)

- Added `"type": "local"` and `"enabled": true` to each MCP server entry in `~/.config/opencode/opencode.jsonc`.
- Updated `scripts/setup-token-optimizer.sh` and `scripts/run-benchmark.sh` to generate MCP servers with the new required fields.
- OpenCode's config schema now requires `type` ("local" | "remote") and `enabled` (boolean) for every `mcp.<name>` entry.
- none

## 2026-05-20 01:15 — Flatten mcp config; command must be array

- Removed the nested `"servers"` wrapper: `mcp` now maps server-name -> config directly (per opencode.ai/docs/mcp-servers).
- Merged `command` + `args` into a single `command: [bin, ...args]` array as required by schema.
- Setup script now migrates legacy `mcp.servers.*` entries into the flat layout.
- none

## 2026-05-20 01:22 — Normalize legacy MCP configs in setup script

- Added normalization loop to `setup-token-optimizer.sh` that converts existing `command`+`args` into `command` array and strips non-schema `description`.
- Prevents re-running the script from preserving invalid legacy fields.
- none

## 2026-05-20 02:06 — Add opencode-lcm plugin (merged to main)

- Added `opencode-lcm` install step and plugin config with DCP interop to `setup-token-optimizer.sh`.
- Updated `run-benchmark.sh` and `scripts/README.md`.
- Rebuilt branch from current main to avoid reverting graphify fixes from stale `feat/opencode-lcm`.
- none

## 2026-05-19 23:55 — Stack A/B support
- Added context-mode, memsearch packages with --stack-a/--stack-b flags (Stack B is default)
- memsearch only installs on Stack B; context-mode in both
- Follow-ups: token-savior removed 2026-05-21 (broken MCP implementation)

## 2026-05-21 00:40 — Add stack-lock.json and maintain-stack.sh

- Created `stack-lock.json` to track known-good versions of all Python/npm/git/cargo dependencies.
- fastmcp pinned to `==3.2.4` because `3.3.0+` breaks `code-review-graph` MCP prompt rendering (dict vs Message objects).
- Created `scripts/maintain-stack.sh` with modes: check, --update, --update-all, --verify, --lock.
- Installer now reads constraints from lockfile and pins fastmcp before installing other Python packages.
- Pinned fastmcp on local system; opencode should work again.
- code-review-graph remains disabled as MCP server (prompt implementation fundamentally broken — use as CLI tool instead).

## 2026-05-21 00:45 — Remove token-savior from stack

- Removed `token-savior` package from installer, lockfile, maintenance script, README, and AGENTS.md template.
- Reason: MCP implementation broken (method not found errors, never fully compatible with opencode's MCP client).
- fastmcp pinReason updated to remove token-savior mention.
- Step numbers renumbered in setup-token-optimizer.sh after removal.
- none
