#!/usr/bin/env bash
set -e

# vibing.nvim build script
# Automatically builds the MCP server on plugin installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="${SCRIPT_DIR}/mcp-server"

echo "[vibing.nvim] Building MCP server..."

# Check if Node.js is installed
if ! command -v node &> /dev/null; then
    echo "[vibing.nvim] Error: Node.js not found. Please install Node.js 18+ from https://nodejs.org/"
    exit 1
fi

# Check Node.js version
NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
if [ "$NODE_VERSION" -lt 18 ]; then
    echo "[vibing.nvim] Warning: Node.js version 18+ recommended (found: $(node -v))"
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

# Build MCP server
cd "$MCP_DIR"

echo "[vibing.nvim] Installing dependencies..."
npm install --silent

echo "[vibing.nvim] Building TypeScript..."
npm run build --silent

# Verify build succeeded
if [ -f "dist/index.js" ]; then
    echo "[vibing.nvim] ✓ MCP server built successfully"
    exit 0
else
    echo "[vibing.nvim] ✗ Build failed: dist/index.js not found"
    exit 1
fi
