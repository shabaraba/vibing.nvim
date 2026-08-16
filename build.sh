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

# Record the fingerprint run.mjs's self-build check compares against (same
# algorithm, via bin/build-fingerprint.mjs), so the plugin cache's run.mjs
# recognizes this build as fresh on first launch instead of running `npm ci`
# over the node_modules symlink set up below and replacing it with a real
# copy until the next build.sh run re-links it.
"$NODE_EXECUTABLE" bin/write-fingerprint.mjs

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
    MARKETPLACE_NAME="vibing"
    PLUGIN_ID="vibing-nvim@${MARKETPLACE_NAME}"
    # Pre-rename identifiers, kept only for the one-time migration cleanup below.
    OLD_MARKETPLACE_NAME="vibing-nvim"
    OLD_PLUGIN_ID="vibing-nvim@${OLD_MARKETPLACE_NAME}"
    PLUGIN_INSTALL_HINT="claude plugin marketplace add $SCRIPT_DIR && claude plugin install ${PLUGIN_ID} --scope user"
    if command -v claude &> /dev/null; then
        # Remove any legacy direct "vibing-nvim" mcpServers registration (e.g. from
        # `claude mcp add` predating the plugin-based install above, or a leftover
        # ~/.claude.json entry). That path hardcodes a single RPC port and silently
        # targets the wrong Neovim instance whenever more than one is running, so it
        # must not coexist with the plugin registration. Ignore failure: this is a
        # no-op when no such entry exists.
        claude mcp remove vibing-nvim --scope user &> /dev/null || true

        # Fetch the installed-plugin list once up front and reuse it below for the
        # migration-cleanup check, the already-installed check, and (after a
        # refresh) the installPath lookup, instead of asking `claude` — slow on at
        # least one real machine in this project's history — for the same data
        # repeatedly. Re-fetched only after an operation that actually changes it
        # (a fresh install, or the migration cleanup below).
        PLUGIN_LIST_JSON="$(run_with_timeout "$CLAUDE_CLI_LIST_TIMEOUT" claude plugin list --json 2>/dev/null)" || true

        # Remove the pre-rename "vibing-nvim" marketplace/plugin registration (this
        # marketplace was renamed to "vibing" so the plugin-scoped MCP tool prefix
        # isn't mcp__plugin_vibing-nvim_vibing-nvim__* — see git history), but only
        # when there's actual evidence of it in the plugin list. `claude plugin
        # marketplace add` on the same directory does not migrate an existing
        # registration to the new name on its own, so without this an upgrading
        # user would end up with both the old and new marketplace/plugin registered
        # side by side — reintroducing the very duplicate-tool-name problem this
        # rename fixed, just under two names instead of one. Gating on the list
        # (rather than running unconditionally) keeps this a one-time cost during
        # the migration window instead of two extra `claude` CLI spawns on every
        # future build forever.
        if echo "$PLUGIN_LIST_JSON" | "$NODE_EXECUTABLE" -e "process.exit(JSON.parse(require('fs').readFileSync(0,'utf8')||'[]').some(p=>p.id==='${OLD_PLUGIN_ID}')?0:1)" 2>/dev/null; then
            run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin uninstall "$OLD_PLUGIN_ID" &> /dev/null || true
            run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin marketplace remove "$OLD_MARKETPLACE_NAME" &> /dev/null || true
            PLUGIN_LIST_JSON="$(run_with_timeout "$CLAUDE_CLI_LIST_TIMEOUT" claude plugin list --json 2>/dev/null)" || true
        fi

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
        elif echo "$PLUGIN_LIST_JSON" | "$NODE_EXECUTABLE" -e "process.exit(JSON.parse(require('fs').readFileSync(0,'utf8')||'[]').some(p=>p.id==='${PLUGIN_ID}')?0:1)" 2>/dev/null; then
            # Already installed: `claude plugin install` is a no-op here, so on repeat
            # runs (e.g. `:Lazy update` re-invoking this script) it won't pick up
            # skill/agent changes on its own. Explicitly refresh the marketplace
            # pointer and re-sync the cached plugin snapshot to the current commit.
            echo "[vibing.nvim] vibing-nvim plugin already installed; refreshing cache..."
            # See the MARKETPLACE_ADD_STATUS comment above for why the fallback is
            # attached via `||` on the same line rather than a separate `STATUS=$?`.
            MARKETPLACE_UPDATE_STATUS=0
            MARKETPLACE_UPDATE_OUTPUT="$(run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin marketplace update "$MARKETPLACE_NAME" 2>&1)" || MARKETPLACE_UPDATE_STATUS=$?
            PLUGIN_UPDATE_OUTPUT=""
            PLUGIN_UPDATE_STATUS=1
            if [ $MARKETPLACE_UPDATE_STATUS -eq 0 ]; then
                PLUGIN_UPDATE_STATUS=0
                PLUGIN_UPDATE_OUTPUT="$(run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin update "$PLUGIN_ID" 2>&1)" || PLUGIN_UPDATE_STATUS=$?
            fi
            if [ $MARKETPLACE_UPDATE_STATUS -eq 0 ] && [ $PLUGIN_UPDATE_STATUS -eq 0 ]; then
                echo "[vibing.nvim] ✓ Synced vibing-nvim plugin cache (restart Claude Code to apply)"
            elif [ $MARKETPLACE_UPDATE_STATUS -ne 0 ]; then
                echo "[vibing.nvim] ⚠ Warning: 'claude plugin marketplace update' failed"
                echo "$MARKETPLACE_UPDATE_OUTPUT"
                echo "[vibing.nvim] You can manually sync by running: claude plugin marketplace update $MARKETPLACE_NAME && claude plugin update $PLUGIN_ID"
            else
                echo "[vibing.nvim] ⚠ Warning: 'claude plugin update' failed"
                echo "$PLUGIN_UPDATE_OUTPUT"
                echo "[vibing.nvim] You can manually sync by running: claude plugin marketplace update $MARKETPLACE_NAME && claude plugin update $PLUGIN_ID"
            fi
        else
            echo "[vibing.nvim] Installing vibing-nvim as a Claude Code plugin (user scope)..."
            if run_with_timeout "$CLAUDE_CLI_TIMEOUT" claude plugin install "$PLUGIN_ID" --scope user; then
                echo "[vibing.nvim] ✓ Installed vibing-nvim Claude Code plugin (scope: user)"
                # The snapshot above predates this install, so it won't have an
                # installPath for $PLUGIN_ID yet — refetch before using it below.
                PLUGIN_LIST_JSON="$(run_with_timeout "$CLAUDE_CLI_LIST_TIMEOUT" claude plugin list --json 2>/dev/null)" || true
            else
                echo "[vibing.nvim] ⚠ Warning: 'claude plugin install' failed"
                echo "[vibing.nvim] You can manually install by running: $PLUGIN_INSTALL_HINT"
            fi
        fi

        # `claude plugin update` treats a matching git commit SHA as "already up to
        # date" and never re-copies — which, for a "directory"-source (dev-mode)
        # plugin whose whole point is tracking uncommitted local edits, means it
        # silently skips syncing on every single build.sh run where HEAD hasn't
        # moved. So sync this checkout's plugin tree into the cache directly on
        # every run, rather than only when detected as broken.
        #
        # This block predates the claude-plugin/ layout, when `source` was the
        # repository root and the CLI's own copy step ran over ~700MB / ~26k files
        # per snapshot — slow enough on a machine with real-time antivirus/EDR
        # scanning (observed on a corporate-managed Mac) that it could stop partway
        # while still updating its bookkeeping as if it finished. That copy is now
        # ~60 files, so the incomplete-snapshot failure is largely retired; the
        # SHA-skip above is what keeps this sync load-bearing.
        #
        # mcp-server/node_modules and mcp-server/dist are symlinked into the cache
        # rather than copied, for two reasons: (1) rsync/cp copying node_modules'
        # thousands of small files is exactly the kind of slow-on-this-machine
        # operation that produced the incomplete snapshot in the first place, and
        # doing it here would just as easily blow past lazy.nvim's own build-step
        # timeout; (2) a symlink means a later `npm run build` here is reflected
        # immediately without rerunning this sync.
        PLUGIN_INSTALL_PATH="$(echo "$PLUGIN_LIST_JSON" | "$NODE_EXECUTABLE" -e "
          const plugins = JSON.parse(require('fs').readFileSync(0, 'utf8') || '[]');
          const p = plugins.find((p) => p.id === '${PLUGIN_ID}');
          process.stdout.write(p && p.installPath ? p.installPath : '');
        " 2>/dev/null)"

        if [ -n "$PLUGIN_INSTALL_PATH" ]; then
            echo "[vibing.nvim] Syncing plugin cache with this checkout..."
            # A partial-copy failure here (permission errors, EDR/antivirus
            # interference — the exact class of environment this sync exists
            # to work around) must not abort the rest of build.sh under `set
            # -e`, the way every other `claude plugin ...` call above already
            # tolerates failure. Capture the status via `||` instead of
            # letting a failing command be the tail of its own statement.
            SYNC_STATUS=0
            if command -v rsync &> /dev/null; then
                rsync -a --delete --exclude='/mcp-server/node_modules' --exclude='/mcp-server/dist' "$PLUGIN_SRC_DIR/" "$PLUGIN_INSTALL_PATH/" || SYNC_STATUS=$?
            else
                # Portable fallback without rsync. Copy each top-level entry
                # individually and skip the excluded ones outright, rather than
                # `cp -R` the whole tree and `rm -rf` them after: on a repeat run,
                # the destination's mcp-server/node_modules and mcp-server/dist are
                # already symlinks back into this very checkout (from the symlink
                # step below), and `cp -R` landing on an existing symlink follows it
                # — copying this checkout's node_modules into itself through the
                # link — instead of replacing it.
                for entry in "$PLUGIN_SRC_DIR"/* "$PLUGIN_SRC_DIR"/.[!.]*; do
                    [ -e "$entry" ] || continue
                    [ "$entry" = "$MCP_DIR" ] && continue
                    cp -R "$entry" "$PLUGIN_INSTALL_PATH/" || SYNC_STATUS=$?
                done
                # Only this loop copies *into* the destination's mcp-server/, so it
                # is the only one that needs the directory to exist first.
                mkdir -p "$PLUGIN_INSTALL_PATH/mcp-server"
                for entry in "$MCP_DIR"/* "$MCP_DIR"/.[!.]*; do
                    [ -e "$entry" ] || continue
                    name="${entry##*/}"
                    [ "$name" = "node_modules" ] && continue
                    [ "$name" = "dist" ] && continue
                    cp -R "$entry" "$PLUGIN_INSTALL_PATH/mcp-server/" || SYNC_STATUS=$?
                done
            fi
            if [ "$SYNC_STATUS" -ne 0 ]; then
                echo "[vibing.nvim] ⚠ Warning: plugin cache sync failed (exit $SYNC_STATUS); cache may be incomplete"
            fi

            # Unconditionally (re)point node_modules/dist at this live checkout's own
            # build output rather than only when missing: an earlier run of this
            # script, or an earlier version of it, may have left a real (now stale)
            # copy behind instead of a symlink, and `ln -sfn` is instant either way so
            # there's no cost to always re-asserting it.
            if [ -d "$PLUGIN_INSTALL_PATH/mcp-server" ]; then
                [ -L "$PLUGIN_INSTALL_PATH/mcp-server/node_modules" ] || rm -rf "$PLUGIN_INSTALL_PATH/mcp-server/node_modules"
                [ -L "$PLUGIN_INSTALL_PATH/mcp-server/dist" ] || rm -rf "$PLUGIN_INSTALL_PATH/mcp-server/dist"
                ln -sfn "$MCP_DIR/node_modules" "$PLUGIN_INSTALL_PATH/mcp-server/node_modules"
                ln -sfn "$MCP_DIR/dist" "$PLUGIN_INSTALL_PATH/mcp-server/dist"
            fi

            if [ -f "$PLUGIN_INSTALL_PATH/mcp-server/bin/run.mjs" ] && [ -d "$PLUGIN_INSTALL_PATH/mcp-server/node_modules" ]; then
                echo "[vibing.nvim] ✓ Plugin cache OK (restart Claude Code to apply any changes)"
            else
                echo "[vibing.nvim] ✗ Repair failed; mcp-server/ still incomplete under $PLUGIN_INSTALL_PATH"
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
