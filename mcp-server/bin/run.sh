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
# does not depend on PATH at all.
#
# .node-path is gitignored (machine-specific), so a manual `/plugin install`
# that never ran build.sh won't have it. In that case, fall back to a bare
# PATH lookup, then to common version-manager install locations that a
# minimal PATH wouldn't include either.
DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
NODE_BIN="$(cat "$DIR/.node-path" 2>/dev/null || true)"

if [ ! -x "$NODE_BIN" ] && command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
fi

if [ ! -x "$NODE_BIN" ]; then
  for candidate in \
    "$HOME/.local/share/mise/shims/node" \
    "$HOME/.asdf/shims/node" \
    "$HOME/.volta/bin/node" \
    /opt/homebrew/bin/node \
    /usr/local/bin/node \
    /usr/bin/node
  do
    if [ -x "$candidate" ]; then
      NODE_BIN="$candidate"
      break
    fi
  done
fi

if [ ! -x "$NODE_BIN" ]; then
  # nvm has no fixed shim path (each version lives in its own directory); take
  # the lexically-last match as a reasonable guess at the newest one.
  for candidate in "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$candidate" ] && NODE_BIN="$candidate"
  done
fi

if [ ! -x "$NODE_BIN" ]; then
  echo "vibing-nvim MCP server: no working node executable found." >&2
  echo "Run ./build.sh once from the plugin checkout to record one, or set VIBING_NODE_EXECUTABLE and re-run it." >&2
  exit 1
fi

# Also put node's own directory on PATH (not just exec it by absolute path):
# run.mjs's self-build step shells out to `npm`, which hits the exact same
# "not on Claude Code's minimal PATH" problem this launcher exists to solve.
# npm ships alongside node in every installation method above, so this is
# free once NODE_BIN is known.
PATH="$(dirname "$NODE_BIN"):$PATH"
export PATH

exec "$NODE_BIN" "$DIR/run.mjs" "$@"
