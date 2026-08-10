#!/usr/bin/env bash
set -e

# vibing.nvim build script
# Automatically builds the MCP server on plugin installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="${SCRIPT_DIR}/mcp-server"

# Use VIBING_NODE_EXECUTABLE env var if set, otherwise default to "node"
NODE_EXECUTABLE="${VIBING_NODE_EXECUTABLE:-node}"

# Timeouts (seconds) for `claude` CLI calls in the plugin-registration block below.
# `claude plugin list --json` only reads local state, so it gets a shorter budget
# than the marketplace/plugin subcommands, which may hit the network.
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
# Needed because `claude plugin ...` invocations below can hang indefinitely on
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

# Install root dependencies (Agent SDK, etc.)
echo "[vibing.nvim] Installing root dependencies..."
cd "$SCRIPT_DIR"
npm install --silent

# Build bin/ files (bundle and minify .mjs/.ts files)
echo "[vibing.nvim] Building bin/ files..."
npm run build

# Clean up old mote binaries (version mismatch prevention)
echo "[vibing.nvim] Cleaning up old mote binaries..."
rm -f bin/mote-darwin-arm64 bin/mote-darwin-x64 bin/mote-linux-arm64 bin/mote-linux-x64

# Download mote binaries for all platforms
echo "[vibing.nvim] Downloading mote binaries..."
if ! "$NODE_EXECUTABLE" scripts/download-mote.mjs; then
    echo "[vibing.nvim] ⚠ Warning: mote binary download failed"
    echo "[vibing.nvim] mote integration will not be available"
    echo "[vibing.nvim] You can manually download by running: $NODE_EXECUTABLE scripts/download-mote.mjs"
fi

# Build MCP server
cd "$MCP_DIR"

echo "[vibing.nvim] Installing MCP server dependencies..."
npm install --silent

echo "[vibing.nvim] Building TypeScript..."
npm run build --silent

# Verify build succeeded
if [ -f "dist/index.js" ]; then
    echo "[vibing.nvim] ✓ MCP server built successfully"

    # Register vibing-nvim with Claude Code exclusively as a proper Claude Code
    # plugin (user scope) — this registers the MCP server *and* the bundled
    # skills/agents in one step. There is intentionally no raw ~/.claude.json
    # mcpServers fallback: that path can only ever hardcode a single default
    # RPC port, so it silently targets the wrong Neovim instance whenever more
    # than one is running (see cli_command_builder.lua's rpc_port handling).
    cd "$SCRIPT_DIR"
    PLUGIN_INSTALL_HINT="claude plugin marketplace add $SCRIPT_DIR && claude plugin install vibing-nvim@vibing-nvim --scope user"
    if command -v claude &> /dev/null; then
        # Remove any legacy direct "vibing-nvim" mcpServers registration (e.g. from
        # `claude mcp add` predating the plugin-based install above, or a leftover
        # ~/.claude.json entry). That path hardcodes a single RPC port and silently
        # targets the wrong Neovim instance whenever more than one is running, so it
        # must not coexist with the plugin registration. Ignore failure: this is a
        # no-op when no such entry exists.
        claude mcp remove vibing-nvim --scope user &> /dev/null || true

        # Capture output instead of streaming it directly so it can be printed
        # below only on failure, keeping successful (repeat) runs quiet.
        # `... || STATUS=$?` (rather than a bare `STATUS=$?` on the next line) is
        # required under `set -e`: a plain `VAR="$(cmd)"` assignment fails the
        # *script* the moment cmd's timeout/error trips a non-zero exit, before
        # the "if $STATUS -ne 0" fallback below ever runs. A command is exempt
        # from set -e only when it isn't the final element of a && / || list, so
        # attaching the fallback via `||` on the same line keeps the assignment's
        # own failure from aborting the script while still capturing its status.
        MARKETPLACE_ADD_STATUS=0
        MARKETPLACE_ADD_OUTPUT="$(run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin marketplace add "$SCRIPT_DIR" 2>&1)" || MARKETPLACE_ADD_STATUS=$?
        if [ $MARKETPLACE_ADD_STATUS -ne 0 ]; then
            echo "[vibing.nvim] ⚠ Warning: 'claude plugin marketplace add' failed"
            echo "$MARKETPLACE_ADD_OUTPUT"
            echo "[vibing.nvim] You can manually install by running: $PLUGIN_INSTALL_HINT"
        # Query installed state as JSON rather than grepping the human-readable table
        # (`claude plugin list`), whose "❯" marker/formatting is a display detail,
        # not a stable contract to match against.
        elif run_with_timeout "$CLAUDE_CLI_LIST_TIMEOUT" claude plugin list --json 2>/dev/null | "$NODE_EXECUTABLE" -e "process.exit(JSON.parse(require('fs').readFileSync(0,'utf8')||'[]').some(p=>p.id==='vibing-nvim@vibing-nvim')?0:1)" 2>/dev/null; then
            # Already installed: `claude plugin install` is a no-op here, so on repeat
            # runs (e.g. `:Lazy update` re-invoking this script) it won't pick up
            # skill/agent changes on its own. Explicitly refresh the marketplace
            # pointer and re-sync the cached plugin snapshot to the current commit.
            echo "[vibing.nvim] vibing-nvim plugin already installed; refreshing cache..."
            # See the MARKETPLACE_ADD_STATUS comment above for why the fallback is
            # attached via `||` on the same line rather than a separate `STATUS=$?`.
            MARKETPLACE_UPDATE_STATUS=0
            MARKETPLACE_UPDATE_OUTPUT="$(run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin marketplace update vibing-nvim 2>&1)" || MARKETPLACE_UPDATE_STATUS=$?
            PLUGIN_UPDATE_OUTPUT=""
            PLUGIN_UPDATE_STATUS=1
            if [ $MARKETPLACE_UPDATE_STATUS -eq 0 ]; then
                PLUGIN_UPDATE_STATUS=0
                PLUGIN_UPDATE_OUTPUT="$(run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin update vibing-nvim@vibing-nvim 2>&1)" || PLUGIN_UPDATE_STATUS=$?
            fi
            if [ $MARKETPLACE_UPDATE_STATUS -eq 0 ] && [ $PLUGIN_UPDATE_STATUS -eq 0 ]; then
                echo "[vibing.nvim] ✓ Synced vibing-nvim plugin cache (restart Claude Code to apply)"
            elif [ $MARKETPLACE_UPDATE_STATUS -ne 0 ]; then
                echo "[vibing.nvim] ⚠ Warning: 'claude plugin marketplace update' failed"
                echo "$MARKETPLACE_UPDATE_OUTPUT"
                echo "[vibing.nvim] You can manually sync by running: claude plugin marketplace update vibing-nvim && claude plugin update vibing-nvim@vibing-nvim"
            else
                echo "[vibing.nvim] ⚠ Warning: 'claude plugin update' failed"
                echo "$PLUGIN_UPDATE_OUTPUT"
                echo "[vibing.nvim] You can manually sync by running: claude plugin marketplace update vibing-nvim && claude plugin update vibing-nvim@vibing-nvim"
            fi
        else
            echo "[vibing.nvim] Installing vibing-nvim as a Claude Code plugin (user scope)..."
            if run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin install vibing-nvim@vibing-nvim --scope user; then
                echo "[vibing.nvim] ✓ Installed vibing-nvim Claude Code plugin (scope: user)"
            else
                echo "[vibing.nvim] ⚠ Warning: 'claude plugin install' failed"
                echo "[vibing.nvim] You can manually install by running: $PLUGIN_INSTALL_HINT"
            fi
        fi
    else
        echo "[vibing.nvim] ⚠ 'claude' CLI not found; skipping Claude Code plugin registration"
        echo "[vibing.nvim] Install Claude Code, then run: $PLUGIN_INSTALL_HINT"
    fi

    MCP_SERVER_PATH="${MCP_DIR}/dist/index.js"
    # Quoted so paths containing spaces stay a single argument when the user copy-pastes the hint
    MANUAL_MCP_ARGS="$(printf '%q %q' "$NODE_EXECUTABLE" "$MCP_SERVER_PATH")"

    # Register the built MCP server with a CLI that speaks `<cli> mcp add`.
    # Both codex and copilot exit 1 when the name already exists, so an existing entry is
    # detected first and left untouched — re-running build.sh must not report a false failure,
    # and a hand-edited config must never be clobbered.
    register_mcp_server() {
        local cli="$1"
        command -v "$cli" &> /dev/null || return 0

        if "$cli" mcp list 2>/dev/null | grep -qE '^[[:space:]]*vibing-nvim[[:space:]]'; then
            echo "[vibing.nvim] ✓ vibing-nvim MCP server already registered with $cli"
            echo "[vibing.nvim] To update it: $cli mcp remove vibing-nvim && $cli mcp add vibing-nvim -- $MANUAL_MCP_ARGS"
            return 0
        fi

        echo "[vibing.nvim] Registering MCP server with $cli..."
        if VIBING_RPC_PORT="${VIBING_RPC_PORT:-9876}" "$cli" mcp add vibing-nvim -- "$NODE_EXECUTABLE" "$MCP_SERVER_PATH" 2>/dev/null; then
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
