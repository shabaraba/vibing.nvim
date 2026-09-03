#!/usr/bin/env bash
#
# SessionStart hook for Claude Code on the web.
#
# The remote container ships node and git but neither Neovim nor a Lua compiler, so four of
# this repository's five gates cannot even start there: `test:lua`, `test:e2e` and `check:doc`
# invoke `nvim`, and `check` invokes `luac`. This installs what they need, mirroring the
# "Setup Neovim" / "Install plenary.nvim" / "Install Lua" steps of .github/workflows/ci.yml so
# a web session passes and fails on the same things CI does.
#
# It is deliberately synchronous: the first thing a session here typically does is run the
# suite, and an async hook would let that start against a half-installed environment.
set -euo pipefail

# A local machine already has the developer's own Neovim, package manager and Lua. Touching
# /opt and /usr/local there would be rude and is never what is wanted.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# CI pins `version: stable` via rhysd/action-setup-vim, so this tracks the same tag rather than
# a number that would silently drift away from it. Override to reproduce a version-specific bug.
NVIM_VERSION="${VIBING_NVIM_VERSION:-stable}"
NVIM_PREFIX="${VIBING_NVIM_PREFIX:-/opt/nvim}"

# tests/minimal_init.lua resolves plenary from `vim.fn.stdpath("data")`, which honours
# XDG_DATA_HOME — so this has to as well, or the clone lands where nothing looks for it.
PLENARY_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/nvim/site/pack/vendor/start/plenary.nvim"

# Progress goes to stderr. A SessionStart hook's stdout is prepended to the session as context,
# and none of this is worth the tokens; stderr is still surfaced when the hook fails.
log() { printf '[session-start] %s\n' "$*" >&2; }

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

install_neovim() {
  if command -v nvim >/dev/null 2>&1; then
    log "neovim present: $(nvim --version | head -1)"
    return
  fi

  local arch
  case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      log "ERROR: no Neovim release for $(uname -m)"
      return 1
      ;;
  esac

  local tarball="nvim-linux-${arch}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  log "downloading ${tarball} (${NVIM_VERSION})"
  curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/${tarball}" \
    "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/${tarball}"

  $SUDO mkdir -p "${NVIM_PREFIX}"
  $SUDO tar -xzf "${tmp}/${tarball}" -C "${NVIM_PREFIX}" --strip-components=1
  $SUDO ln -sf "${NVIM_PREFIX}/bin/nvim" /usr/local/bin/nvim

  log "installed $(nvim --version | head -1)"
}

install_plenary() {
  if [ -d "${PLENARY_DIR}/.git" ]; then
    log "plenary.nvim present"
    return
  fi
  # A directory that exists without a .git is a half-finished clone from an interrupted run;
  # git clone would refuse it, so clear it rather than fail every session from here on.
  rm -rf "${PLENARY_DIR}"
  mkdir -p "$(dirname "${PLENARY_DIR}")"
  log "cloning plenary.nvim"
  git clone --depth 1 --quiet https://github.com/nvim-lua/plenary.nvim "${PLENARY_DIR}"
}

install_luac() {
  if command -v luac >/dev/null 2>&1; then
    log "luac present: $(luac -v 2>&1 | head -1)"
    return
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    log "ERROR: no apt-get; cannot install lua5.3"
    return 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  # The image usually carries usable package lists already, so try the install first and pay
  # for `apt-get update` only when it is actually needed.
  $SUDO apt-get install -y -qq lua5.3 >/dev/null 2>&1 || {
    log "refreshing package lists"
    $SUDO apt-get update -qq >/dev/null
    $SUDO apt-get install -y -qq lua5.3 >/dev/null
  }

  # Debian's alternatives normally provide a bare `luac`, which is the name package.json's
  # `check` script calls. Link it directly if they did not.
  command -v luac >/dev/null 2>&1 || $SUDO ln -sf /usr/bin/luac5.3 /usr/local/bin/luac

  log "installed $(luac -v 2>&1 | head -1)"
}

install_node_deps() {
  [ -f "${PROJECT_DIR}/package.json" ] || return 0
  log "npm install"
  # `install`, not `ci`: the container image is cached after this hook completes, and install
  # reuses an existing node_modules where ci deletes and refetches it every time.
  (cd "${PROJECT_DIR}" && npm install --no-audit --no-fund --loglevel=error >&2)
}

install_neovim
install_plenary
install_luac
install_node_deps

# Verify rather than assume. A hook that reports success over a half-installed environment is
# the exact failure this one exists to prevent — the session would then blame the repository
# for an error that belongs to its own setup.
missing=()
command -v nvim >/dev/null 2>&1 || missing+=("nvim")
command -v luac >/dev/null 2>&1 || missing+=("luac")
[ -d "${PLENARY_DIR}" ] || missing+=("plenary.nvim")
[ -d "${PROJECT_DIR}/node_modules" ] || missing+=("node_modules")

if [ "${#missing[@]}" -gt 0 ]; then
  log "ERROR: setup incomplete, still missing: ${missing[*]}"
  exit 1
fi

log "ready: npm run check / check:doc / test:lua / test:node are all runnable"
