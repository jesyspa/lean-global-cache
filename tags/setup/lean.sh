#!/usr/bin/env bash
# Setup for `lean`-tagged repos (run for both fresh clones and worktrees).
# - Overlays .lake/packages onto the shared read-only Mathlib cache via
#   `lean-cache use`, so Mathlib isn't re-downloaded. `use` derives the
#   version from the project's lean-toolchain, is idempotent, and installs a
#   post-checkout hook so future worktrees re-establish the overlay.
# - Drops .mcp.json registering the lean-lsp MCP server. The discord-listener
#   install (listeners/discord-listener/install.sh) pre-trusts "lean-lsp" via
#   enabledMcpjsonServers in each bot's ~/.claude/settings.json, so the server
#   loads without a first-use prompt the bot couldn't answer. That same install
#   adds .mcp.json to the bot user's git excludes, so this host-local file
#   doesn't show up as untracked in the worktree.
set -euo pipefail

if [[ ! -f .mcp.json ]]; then
  cat > .mcp.json <<'JSON'
{
  "mcpServers": {
    "lean-lsp": {
      "type": "stdio",
      "command": "uvx",
      "args": ["lean-lsp-mcp"]
    }
  }
}
JSON
fi

# lean-cache use overlays the repo root, or each Lake project beneath it.
exec /opt/bots/bin/lean-cache use
