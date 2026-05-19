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
