#!/bin/sh
# Launcher for the vibing-nvim MCP server, invoked by Claude Code via the
# `command`/`args` declared in ../../.claude-plugin/plugin.json.
#
# Claude Code spawns plugin-declared MCP server commands with a minimal PATH
# that does not include version-manager shims (mise, nvm, volta, asdf, ...),
# so a bare `command: "node"` fails with "Executable not found in $PATH" on
# any machine where node is only installed through one of those (not through
# an OS-default location like /usr/local/bin or /opt/homebrew/bin). build.sh
# records the exact node binary it resolved (and used to build this plugin)
# into .node-path; invoke that directly by absolute path so this launcher
# does not depend on PATH at all. Falls back to a bare `node` PATH lookup for
# a fresh checkout that hasn't been built yet.
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NODE_BIN="$(cat "$DIR/.node-path" 2>/dev/null || true)"
[ -x "$NODE_BIN" ] || NODE_BIN="node"
exec "$NODE_BIN" "$DIR/run.mjs" "$@"
