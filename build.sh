#!/usr/bin/env bash
set -e

# vibing.nvim build script
# Automatically builds the MCP server on plugin installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="${SCRIPT_DIR}/mcp-server"

# Use VIBING_NODE_EXECUTABLE env var if set, otherwise default to "node"
NODE_EXECUTABLE="${VIBING_NODE_EXECUTABLE:-node}"

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

# Build MCP server
cd "$MCP_DIR"

echo "[vibing.nvim] Installing MCP server dependencies..."
npm install --silent

echo "[vibing.nvim] Building TypeScript..."
npm run build --silent

# Verify build succeeded
if [ -f "dist/index.js" ]; then
    echo "[vibing.nvim] ✓ MCP server built successfully"

    # Register MCP server in ~/.claude.json
    cd "$SCRIPT_DIR"
    echo "[vibing.nvim] Registering MCP server in ~/.claude.json..."
    if "$NODE_EXECUTABLE" dist/bin/register-mcp.js; then
        exit 0
    else
        echo "[vibing.nvim] ⚠ Warning: MCP server is built but registration failed"
        echo "[vibing.nvim] You can manually register by running: $NODE_EXECUTABLE dist/bin/register-mcp.js"
        # Build succeeded but registration failed - still exit 0 since MCP server is functional
        exit 0
    fi
else
    echo "[vibing.nvim] ✗ Build failed: dist/index.js not found"
    exit 1
fi
