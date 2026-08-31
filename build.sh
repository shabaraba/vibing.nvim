#!/usr/bin/env bash
set -e

# vibing.nvim build script
# Automatically builds the MCP server on plugin installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Everything shipped to Claude Code lives under claude-plugin/, which is what
# .claude-plugin/marketplace.json points `source` at. The repository root is the
# *marketplace* root; the plugin root is one level down.
PLUGIN_SRC_DIR="${SCRIPT_DIR}/claude-plugin"
MCP_DIR="${PLUGIN_SRC_DIR}/mcp-server"

# Use VIBING_NODE_EXECUTABLE env var if set, otherwise default to "node"
NODE_EXECUTABLE="${VIBING_NODE_EXECUTABLE:-node}"

# Timeouts (seconds) for the `claude plugin ...` cleanup calls below. Kept even
# though vibing.nvim no longer installs itself as a plugin: uninstalling one is
# the same subcommand family that hangs (#480/#482), and the cleanup runs on
# every build until the user's machine is clean. `claude plugin list --json`
# only reads local state, so it gets a shorter budget than the subcommands that
# may hit the network.
readonly CLAUDE_CLI_LIST_TIMEOUT=30
readonly CLAUDE_CLI_TIMEOUT=60

# Kill a process and everything it forked. Killing only the direct child would
# leave a grandchild alive (e.g. a network helper process spawned by `claude`)
# still holding this script's stdout/stderr open, reproducing the exact hang
# run_with_timeout exists to prevent. There's no grace period (SIGTERM then
# SIGKILL) — by the time this runs, the process is already deemed hung, so
# waiting on it to exit cleanly defeats the point of a hard timeout.
kill_tree() {
    local pid="$1"
    if command -v pgrep &> /dev/null; then
        local child
        for child in $(pgrep -P "$pid" 2>/dev/null); do
            kill_tree "$child"
        done
    fi
    kill -9 "$pid" 2>/dev/null
}

# Run a command with a hard timeout. macOS doesn't ship GNU coreutils' `timeout`,
# so this is implemented with a background watchdog instead of relying on it.
# Needed because `claude plugin ...` invocations can hang indefinitely on
# a stalled network call, which otherwise wedges this script forever and gets
# it killed by the caller's own timeout (e.g. lazy.nvim's build-step timeout),
# skipping every step after it.
run_with_timeout() {
    local timeout_secs="$1"
    shift
    "$@" &
    local cmd_pid=$!
    # Poll in ~1s steps instead of a single `sleep timeout_secs` so that killing
    # this watchdog below (once cmd_pid finishes on its own) only orphans a
    # short-lived sleep, not one holding stdout open for the full timeout — an
    # orphaned child of a killed subshell keeps its inherited fds open until it
    # exits on its own, which would otherwise stall any `$(run_with_timeout ...)`
    # or piped caller for the whole timeout period even on success.
    (
        local elapsed=0
        while kill -0 "$cmd_pid" 2>/dev/null && [ "$elapsed" -lt "$timeout_secs" ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        kill_tree "$cmd_pid"
    ) &
    local watchdog_pid=$!
    wait "$cmd_pid" 2>/dev/null
    local cmd_status=$?
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
    return "$cmd_status"
}

echo "[vibing.nvim] Building MCP server..."

# Check if Node.js is installed
# Handle both absolute paths and PATH lookups
if [[ "$NODE_EXECUTABLE" = /* ]]; then
    # Absolute path - check if file exists and is executable
    if [ ! -x "$NODE_EXECUTABLE" ]; then
        echo "[vibing.nvim] Error: Node.js not found at '$NODE_EXECUTABLE'. Please install Node.js 18+ from https://nodejs.org/"
        exit 1
    fi
else
    # Relative or command name - check PATH
    if ! command -v "$NODE_EXECUTABLE" &> /dev/null; then
        echo "[vibing.nvim] Error: Node.js not found at '$NODE_EXECUTABLE'. Please install Node.js 18+ from https://nodejs.org/"
        exit 1
    fi
fi

# Check Node.js version
NODE_VERSION=$("$NODE_EXECUTABLE" -v | cut -d'v' -f2 | cut -d'.' -f1)
if [ "$NODE_VERSION" -lt 18 ]; then
    echo "[vibing.nvim] Warning: Node.js version 18+ recommended (found: $("$NODE_EXECUTABLE" -v))"
fi

# Check if npm is installed
if ! command -v npm &> /dev/null; then
    echo "[vibing.nvim] Error: npm not found. Please install npm"
    exit 1
fi

# Check if MCP directory exists
if [ ! -d "$MCP_DIR" ]; then
    echo "[vibing.nvim] Error: MCP server directory not found: $MCP_DIR"
    exit 1
fi

# Record the exact node binary resolved above so the Claude Code plugin's MCP
# server launcher (claude-plugin/mcp-server/bin/run.sh) can invoke it directly by absolute
# path instead of relying on `node` being on PATH. Claude Code spawns
# plugin-declared MCP server commands with a minimal PATH that doesn't
# include version-manager shims (mise, nvm, volta, asdf, ...), so a bare
# `command: "node"` fails with "Executable not found in $PATH" on any machine
# where node is only installed through one of those. Written after the
# directory check above so a missing claude-plugin/mcp-server/ checkout fails with that
# clear error instead of a raw redirect failure here. `command -v` is
# guaranteed to succeed here (the checks above already proved $NODE_EXECUTABLE
# is either an executable absolute path or resolvable on PATH), so no extra
# empty-value guard is needed around it.
echo "$(command -v "$NODE_EXECUTABLE")" > "${MCP_DIR}/bin/.node-path"

# Install root dependencies (Agent SDK, etc.)
echo "[vibing.nvim] Installing root dependencies..."
cd "$SCRIPT_DIR"
npm install --silent

# Build bin/ files (bundle and minify .mjs/.ts files)
echo "[vibing.nvim] Building bin/ files..."
npm run build

# One-shot cleanup for checkouts that predate the mote removal. The integration is
# gone (diffs come from a per-request git tree snapshot now), so these downloaded
# binaries are dead weight -- and they are git-ignored, so nothing else deletes them.
rm -f bin/mote-darwin-arm64 bin/mote-darwin-x64 bin/mote-linux-arm64 bin/mote-linux-x64

# Build MCP server
cd "$MCP_DIR"

echo "[vibing.nvim] Installing MCP server dependencies..."
npm install --silent

echo "[vibing.nvim] Building TypeScript..."
npm run build --silent

# Record the fingerprint run.mjs's self-build check compares against (same
# algorithm, via bin/build-fingerprint.mjs), so run.mjs recognizes this build as
# fresh on first launch instead of spending a `npm ci` + `npm run build` on the
# very tree that was just built.
"$NODE_EXECUTABLE" bin/write-fingerprint.mjs

# Verify build succeeded
if [ -f "dist/index.js" ]; then
    echo "[vibing.nvim] ✓ MCP server built successfully"

    # vibing.nvim is NOT installed into Claude Code's global state. Its plugin
    # (claude-plugin/) is handed to the CLI per session with `--plugin-dir`,
    # assembled in lua/vibing/infrastructure/plugins/plugin_dirs.lua. The MCP
    # tool names are identical either way — the prefix comes from plugin.json's
    # `name`, not from how the plugin was loaded (measured on claude 2.1.231).
    #
    # That removes three standing problems at once: `claude plugin ...` calls
    # that hang and needed the watchdog above (#480/#482), a plugin cache that
    # had to be rsync'd and symlinked back to this checkout on every build, and
    # an MCP server that updated independently of the Neovim plugin it serves —
    # so a worktree edited its own copy while a different one actually ran.
    #
    # What remains here is one-shot cleanup for machines that already have the
    # old user-scope install. It is best-effort: an inline `--plugin-dir` plugin
    # wins over an installed one of the same name (measured), so a leftover is
    # inert rather than a conflict.
    cd "$SCRIPT_DIR"
    if command -v claude &> /dev/null; then
        # Legacy direct "vibing-nvim" mcpServers registration (e.g. from `claude
        # mcp add`, predating the plugin install). That path hardcodes a single
        # RPC port and silently targets the wrong Neovim instance whenever more
        # than one is running. No-op when no such entry exists.
        claude mcp remove vibing-nvim --scope user &> /dev/null || true

        # The user-scope plugin install and its marketplace, from before #618 —
        # under the current name and the pre-rename one. These are historical
        # identifiers to clean up, not configuration to follow, which is why they
        # appear nowhere else in the repository any more.
        #
        # Gated on evidence rather than fired unconditionally: this runs on every
        # build, forever, on machines that never had the install, and each
        # `claude plugin ...` call is a process spawn under a 60s watchdog. One
        # `list` answers for all four.
        PLUGIN_LIST_JSON="$(run_with_timeout "$CLAUDE_CLI_LIST_TIMEOUT" claude plugin list --json 2>/dev/null)" || true
        for legacy_marketplace in "vibing" "vibing-nvim"; do
            # The closing quote is part of the pattern on purpose: "vibing-nvim@vibing" is a
            # prefix of "vibing-nvim@vibing-nvim", so an unanchored match would report the
            # pre-rename install as the current one and print a misleading line.
            case "$PLUGIN_LIST_JSON" in
                *"\"vibing-nvim@${legacy_marketplace}\""*)
                    echo "[vibing.nvim] Removing the old user-scope plugin install (vibing-nvim@${legacy_marketplace})..."
                    run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin uninstall "vibing-nvim@${legacy_marketplace}" &> /dev/null || true
                    run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin marketplace remove "$legacy_marketplace" &> /dev/null || true
                    ;;
            esac
        done
    fi

    MCP_SERVER_PATH="${MCP_DIR}/dist/index.js"
    # Quoted so paths containing spaces stay a single argument when the user copy-pastes the hint
    MANUAL_MCP_ARGS="$(printf '%q %q' "$NODE_EXECUTABLE" "$MCP_SERVER_PATH")"

    # Register the built MCP server with a CLI that speaks `<cli> mcp add`.
    # Both codex and copilot exit 1 when the name already exists, so an existing entry is
    # detected first and left untouched — re-running build.sh must not report a false failure,
    # and a hand-edited config must never be clobbered.
    #
    # No port is baked into the registration: the MCP server takes `rpc_port` as an explicit
    # argument on every tool call (claude-plugin/mcp-server/src/rpc.ts throws without it) and reads no port
    # from its environment, so persisting one via `--env` would only enshrine a value nothing
    # reads and mislead anyone running Neovim on a non-default port.
    register_mcp_server() {
        local cli="$1"
        command -v "$cli" &> /dev/null || return 0

        if "$cli" mcp list 2>/dev/null | grep -qE '^[[:space:]]*vibing-nvim[[:space:]]'; then
            # `copilot mcp list` renders a disabled server exactly like an enabled one, so the
            # plain-text hit above is not proof it will actually be launched. Only copilot has
            # this per-server flag and only its --json view exposes it; codex has no equivalent.
            if [ "$cli" = "copilot" ] && copilot mcp list --json 2>/dev/null |
                "$NODE_EXECUTABLE" -e "const e=(JSON.parse(require('fs').readFileSync(0,'utf8')||'{}').mcpServers||{})['vibing-nvim'];process.exit(e&&e.enabled===false?0:1)" 2>/dev/null; then
                echo "[vibing.nvim] ⚠ vibing-nvim MCP server is registered with copilot but disabled"
                echo "[vibing.nvim] Enable it from copilot, or replace it: copilot mcp remove vibing-nvim && copilot mcp add vibing-nvim -- $MANUAL_MCP_ARGS"
                return 0
            fi
            echo "[vibing.nvim] ✓ vibing-nvim MCP server already registered with $cli"
            echo "[vibing.nvim] To update it: $cli mcp remove vibing-nvim && $cli mcp add vibing-nvim -- $MANUAL_MCP_ARGS"
            return 0
        fi

        echo "[vibing.nvim] Registering MCP server with $cli..."
        if "$cli" mcp add vibing-nvim -- "$NODE_EXECUTABLE" "$MCP_SERVER_PATH" 2>/dev/null; then
            echo "[vibing.nvim] ✓ Registered vibing-nvim MCP server with $cli"
        else
            echo "[vibing.nvim] ⚠ Warning: $cli MCP registration failed"
            echo "[vibing.nvim] You can manually register by running: $cli mcp add vibing-nvim -- $MANUAL_MCP_ARGS"
        fi
    }

    register_mcp_server codex
    register_mcp_server copilot

    exit 0
else
    echo "[vibing.nvim] ✗ Build failed: dist/index.js not found"
    exit 1
fi
