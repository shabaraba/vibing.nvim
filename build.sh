#!/usr/bin/env bash
set -e

# vibing.nvim build script
# Automatically builds the MCP server and sets up Ollama on plugin installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="${SCRIPT_DIR}/mcp-server"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# Install root dependencies (Agent SDK, etc.)
echo "[vibing.nvim] Installing root dependencies..."
cd "$SCRIPT_DIR"
npm install --silent

# Build MCP server
cd "$MCP_DIR"

echo "[vibing.nvim] Installing MCP server dependencies..."
npm install --silent

echo "[vibing.nvim] Building TypeScript..."
npm run build --silent

# Verify build succeeded
if [ -f "dist/index.js" ]; then
    echo -e "${GREEN}[vibing.nvim] ✓ MCP server built successfully${NC}"

    # Register MCP server in ~/.claude.json
    cd "$SCRIPT_DIR"
    echo "[vibing.nvim] Registering MCP server in ~/.claude.json..."
    if node bin/register-mcp.mjs; then
        echo -e "${GREEN}[vibing.nvim] ✓ MCP server registered${NC}"
    else
        echo -e "${YELLOW}[vibing.nvim] ⚠ Warning: MCP server is built but registration failed${NC}"
        echo "[vibing.nvim] You can manually register by running: node bin/register-mcp.mjs"
    fi
else
    echo -e "${RED}[vibing.nvim] ✗ Build failed: dist/index.js not found${NC}"
    exit 1
fi

# ===== Ollama Setup (Optional) =====
setup_ollama() {
    echo ""
    echo "[vibing.nvim] ===== Setting up Ollama for local AI ====="

    # 1. Check if Ollama is already installed
    if command -v ollama &> /dev/null; then
        echo -e "${GREEN}[vibing.nvim] ✓ Ollama already installed: $(ollama --version 2>/dev/null || echo 'version unknown')${NC}"
    else
        # 2. Detect OS and install
        case "$(uname -s)" in
            Linux*)
                echo "[vibing.nvim] Installing Ollama for Linux..."
                if curl -fsSL https://ollama.com/install.sh | sh; then
                    echo -e "${GREEN}[vibing.nvim] ✓ Ollama installed successfully${NC}"
                else
                    echo -e "${RED}[vibing.nvim] ✗ Failed to install Ollama${NC}"
                    return 1
                fi
                ;;
            Darwin*)
                if command -v brew &> /dev/null; then
                    echo "[vibing.nvim] Installing Ollama via Homebrew..."
                    if brew install ollama; then
                        echo -e "${GREEN}[vibing.nvim] ✓ Ollama installed successfully${NC}"
                    else
                        echo -e "${RED}[vibing.nvim] ✗ Failed to install Ollama${NC}"
                        return 1
                    fi
                else
                    echo -e "${YELLOW}[vibing.nvim] ⚠ Homebrew not found. Please install Ollama manually:${NC}"
                    echo "    https://ollama.com/download/mac"
                    return 1
                fi
                ;;
            *)
                echo -e "${YELLOW}[vibing.nvim] ⚠ Unsupported OS. Please install Ollama manually:${NC}"
                echo "    https://ollama.com/download"
                return 1
                ;;
        esac
    fi

    # 3. Start Ollama service (must be running before pulling models)
    start_ollama_service

    # 4. Pull the model if not already downloaded
    MODEL="qwen2.5-coder:0.5b"
    echo "[vibing.nvim] Checking model: $MODEL"
    if ollama list 2>/dev/null | grep -q "$MODEL"; then
        echo -e "${GREEN}[vibing.nvim] ✓ Model $MODEL already downloaded${NC}"
    else
        echo "[vibing.nvim] Downloading model $MODEL (~400MB, this may take a few minutes)..."
        if ollama pull "$MODEL"; then
            echo -e "${GREEN}[vibing.nvim] ✓ Model downloaded successfully${NC}"
        else
            echo -e "${RED}[vibing.nvim] ✗ Failed to download model${NC}"
            echo -e "${YELLOW}[vibing.nvim]   Make sure Ollama server is running${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}[vibing.nvim] ✓ Ollama setup complete${NC}"
}

start_ollama_service() {
    # Check if already running
    if curl -s http://localhost:11434/api/tags &> /dev/null; then
        echo -e "${GREEN}[vibing.nvim] ✓ Ollama server already running${NC}"
        return 0
    fi

    case "$(uname -s)" in
        Darwin*)
            echo "[vibing.nvim] Starting Ollama service..."
            # Check if Ollama is managed by brew services
            if brew services list 2>/dev/null | grep -q ollama; then
                if brew services start ollama 2>/dev/null; then
                    echo "[vibing.nvim] Started via brew services"
                fi
            else
                # Fallback to direct start (Ollama.app or command)
                echo "[vibing.nvim] Starting Ollama directly..."
                if [ -d "/Applications/Ollama.app" ]; then
                    open -a Ollama 2>/dev/null
                else
                    nohup ollama serve &>/dev/null &
                fi
            fi
            ;;
        Linux*)
            echo "[vibing.nvim] Starting Ollama service (systemd)..."
            if command -v systemctl &>/dev/null; then
                if sudo systemctl enable ollama 2>/dev/null && sudo systemctl start ollama 2>/dev/null; then
                    echo "[vibing.nvim] Started via systemd"
                fi
            else
                # Fallback to direct start
                nohup ollama serve &>/dev/null &
            fi
            ;;
    esac

    # Wait for server to start (max 15 seconds)
    echo "[vibing.nvim] Waiting for Ollama server to be ready..."
    for i in {1..15}; do
        if curl -s http://localhost:11434/api/tags &> /dev/null; then
            echo -e "${GREEN}[vibing.nvim] ✓ Ollama server is ready${NC}"
            return 0
        fi
        sleep 1
    done

    echo -e "${RED}[vibing.nvim] ✗ Ollama server did not start${NC}"
    echo -e "${YELLOW}[vibing.nvim]   Try starting manually: ollama serve${NC}"
    return 1
}

# Main execution
# MCP build is done above

# Ollama setup (optional, can be skipped with VIBING_SKIP_OLLAMA=1)
if [ "${VIBING_SKIP_OLLAMA:-}" != "1" ]; then
    if ! setup_ollama; then
        echo -e "${YELLOW}[vibing.nvim] ⚠ Ollama setup failed or was skipped${NC}"
        echo "[vibing.nvim] You can set up Ollama later by running: ./build.sh"
        echo "[vibing.nvim] Or skip Ollama setup with: VIBING_SKIP_OLLAMA=1 ./build.sh"
    fi
fi

echo ""
echo -e "${GREEN}[vibing.nvim] ===== Build complete =====${NC}"
exit 0
