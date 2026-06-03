#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# install-mcp.sh — register agent-tts as an MCP server for Claude Code.
#
# Idempotent: re-running does nothing once the server is present.
# Best-effort: if the config schema looks unfamiliar, the script prints
# the snippet and asks you to merge by hand instead of corrupting JSON.
#
# Usage:
#   ./scripts/install-mcp.sh             # writes to ~/.claude.json
#   CLAUDE_CONFIG=/path/to/cfg.json ./scripts/install-mcp.sh

set -euo pipefail

AGENT_TTS_BIN="${AGENT_TTS_BIN:-$(command -v agent-tts || true)}"
if [ -z "$AGENT_TTS_BIN" ]; then
  echo "error: agent-tts not on PATH. Install it first (zig build -Doptimize=ReleaseFast && cp zig-out/bin/agent-tts /opt/homebrew/bin/)." >&2
  exit 1
fi

CFG_PATH="${CLAUDE_CONFIG:-$HOME/.claude.json}"
SNIPPET=$(cat <<JSON
{
  "mcpServers": {
    "agent-tts": {
      "command": "$AGENT_TTS_BIN",
      "args": ["mcp"]
    }
  }
}
JSON
)

if ! command -v jq >/dev/null 2>&1; then
  echo "warn: jq not found — printing snippet, merge by hand into $CFG_PATH:" >&2
  echo "$SNIPPET"
  exit 0
fi

if [ ! -f "$CFG_PATH" ]; then
  echo "info: $CFG_PATH does not exist — creating with agent-tts MCP block." >&2
  echo "$SNIPPET" > "$CFG_PATH"
  echo "ok: wrote $CFG_PATH"
  exit 0
fi

# Validate existing JSON. If it is not a top-level object, refuse to touch it.
if ! jq -e 'type == "object"' "$CFG_PATH" >/dev/null 2>&1; then
  echo "warn: $CFG_PATH is not a JSON object — printing snippet, merge by hand:" >&2
  echo "$SNIPPET"
  exit 0
fi

# Already present? Idempotent exit.
if jq -e '.mcpServers."agent-tts"' "$CFG_PATH" >/dev/null 2>&1; then
  CURRENT=$(jq -r '.mcpServers."agent-tts".command' "$CFG_PATH")
  if [ "$CURRENT" = "$AGENT_TTS_BIN" ]; then
    echo "ok: agent-tts MCP server already configured in $CFG_PATH"
    exit 0
  fi
  echo "info: updating agent-tts MCP server path: $CURRENT → $AGENT_TTS_BIN" >&2
fi

# Backup, then merge.
cp "$CFG_PATH" "$CFG_PATH.bak.$(date +%s)"
TMP=$(mktemp)
jq --arg bin "$AGENT_TTS_BIN" '
  .mcpServers = (.mcpServers // {})
  | .mcpServers."agent-tts" = { "command": $bin, "args": ["mcp"] }
' "$CFG_PATH" > "$TMP"
mv "$TMP" "$CFG_PATH"

echo "ok: registered agent-tts MCP server in $CFG_PATH (backup beside it)"
echo "    restart Claude Code (or your MCP client) to pick up the change."
