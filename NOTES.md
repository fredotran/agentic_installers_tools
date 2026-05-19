## 2026-05-20 00:59 — Remove invalid top-level "dcp" key from opencode.jsonc

- Removed the `cfg["dcp"]` write block from `scripts/setup-token-optimizer.sh` and deleted the existing `"dcp"` object from `~/.config/opencode/opencode.jsonc`.
- OpenCode's config schema no longer recognizes the top-level `"dcp"` key; the `@tarquinen/opencode-dcp` plugin now handles DCP internally.
- none
