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

# The Lua the `check` gate must compile with. CI installs lua5.3; see install_luac for why the
# version is checked rather than assumed.
LUA_VERSION="5.3"

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
  # Keyed on *this hook's own* installation, not on whatever `nvim` happens to be first on
  # PATH. Accepting any nvim would let a build the image ships — an older one, or a distro
  # package — decide what `test:lua` and `check:doc` run against, so the web session would
  # pass and fail on different things than CI, which is the one thing this hook exists to
  # prevent. The link below then puts the managed build ahead of any other.
  if "${NVIM_PREFIX}/bin/nvim" --version >/dev/null 2>&1; then
    log "neovim present: $("${NVIM_PREFIX}/bin/nvim" --version | head -1) (managed)"
    link_neovim
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

  # The `stable` tag publishes no digest of its own (shasum.txt and the per-asset
  # .sha256sum names are all 404), so there is nothing authoritative to compare against and
  # baking one in would break the hook every time upstream moves the tag. Certificate
  # verification on the HTTPS fetch is therefore the integrity boundary here. Pin
  # VIBING_NVIM_VERSION to a real release and set VIBING_NVIM_SHA256 to check a digest.
  if [ -n "${VIBING_NVIM_SHA256:-}" ]; then
    log "verifying sha256"
    printf '%s  %s\n' "${VIBING_NVIM_SHA256}" "${tmp}/${tarball}" | sha256sum -c - >/dev/null
  fi

  # Unpack to a staging directory and smoke-test it before it becomes ${NVIM_PREFIX}. A
  # truncated download extracted in place would leave a prefix that looks managed, and every
  # later run would take the branch above and skip repairing it.
  $SUDO rm -rf "${tmp}/stage"
  mkdir -p "${tmp}/stage"
  tar -xzf "${tmp}/${tarball}" -C "${tmp}/stage" --strip-components=1
  "${tmp}/stage/bin/nvim" --version >/dev/null 2>&1 \
    || { log "ERROR: the downloaded Neovim does not run"; return 1; }

  $SUDO rm -rf "${NVIM_PREFIX}"
  $SUDO mkdir -p "$(dirname "${NVIM_PREFIX}")"
  $SUDO mv "${tmp}/stage" "${NVIM_PREFIX}"
  link_neovim

  log "installed $("${NVIM_PREFIX}/bin/nvim" --version | head -1)"
}

link_neovim() {
  $SUDO ln -sf "${NVIM_PREFIX}/bin/nvim" /usr/local/bin/nvim
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

luac_is_required_version() {
  command -v luac >/dev/null 2>&1 || return 1
  luac -v 2>&1 | head -1 | grep -q "Lua ${LUA_VERSION}\b"
}

install_luac() {
  # The version matters, so `command -v luac` is not enough on its own. CI installs lua5.3,
  # and 5.4 accepts syntax 5.3 rejects — `local x <const> = 1` compiles under 5.4 — so a
  # container whose bare `luac` is 5.4 would let `npm run check` pass here and fail in CI.
  # That is the same divergence the version check above guards against.
  if luac_is_required_version; then
    log "luac present: $(luac -v 2>&1 | head -1)"
    return
  fi
  if command -v luac >/dev/null 2>&1; then
    log "luac is $(luac -v 2>&1 | head -1), but CI uses Lua ${LUA_VERSION}; installing it"
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    log "ERROR: no apt-get; cannot install lua${LUA_VERSION}"
    return 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  # The image usually carries usable package lists already, so try the install first and pay
  # for `apt-get update` only when it is actually needed.
  $SUDO apt-get install -y -qq "lua${LUA_VERSION}" >/dev/null 2>&1 || {
    log "refreshing package lists"
    $SUDO apt-get update -qq >/dev/null
    $SUDO apt-get install -y -qq "lua${LUA_VERSION}" >/dev/null
  }

  # Debian's alternatives provide a bare `luac`, which is the name package.json's `check`
  # script calls — but it may point at another installed version. Name the compiler we want
  # explicitly, in /usr/local/bin so it wins over /usr/bin.
  luac_is_required_version \
    || $SUDO ln -sf "/usr/bin/luac${LUA_VERSION}" /usr/local/bin/luac

  log "installed $(luac -v 2>&1 | head -1)"
}

install_node_deps() {
  [ -f "${PROJECT_DIR}/package.json" ] || return 0

  # `npm ci`, matching CI, because `npm install` **rewrites package-lock.json** when it
  # disagrees with package.json. Two things go wrong when it does: the drift that CI's
  # `npm ci` would reject is silently repaired here instead, so the session passes on a
  # dependency tree CI will refuse; and the rewritten lockfile is a working-tree change, which
  # this repository's per-turn git tree snapshot picks up and lists under `### Modified Files`
  # for whatever turn happens to be running.
  local lock="${PROJECT_DIR}/package-lock.json"
  if [ ! -f "$lock" ]; then
    log "ERROR: no package-lock.json; npm ci needs one (CI uses it too)"
    return 1
  fi

  # `ci` deletes node_modules and refetches every time, which would throw away the container
  # image's cache on every resume. So keep the cache benefit a different way: stamp the
  # lockfile's digest inside node_modules and skip the install entirely while it still
  # matches. The stamp lives in node_modules precisely so `ci` wiping the tree invalidates it.
  local stamp="${PROJECT_DIR}/node_modules/.vibing-session-start-lock"
  local digest
  digest="$(sha256sum "$lock" | cut -d' ' -f1)"
  if [ -d "${PROJECT_DIR}/node_modules" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$digest" ]; then
    log "node_modules already matches package-lock.json"
    return
  fi

  log "npm ci"
  if ! (cd "${PROJECT_DIR}" && npm ci --no-audit --no-fund --loglevel=error >&2); then
    log "ERROR: npm ci failed. If it reports a lockfile mismatch, package.json and"
    log "       package-lock.json disagree — run 'npm install' locally and commit the"
    log "       updated lockfile. CI would reject this too."
    return 1
  fi
  printf '%s\n' "$digest" > "$stamp"
}

install_neovim
install_plenary
install_luac
install_node_deps

# Verify rather than assume. A hook that reports success over a half-installed environment is
# the exact failure this one exists to prevent — the session would then blame the repository
# for an error that belongs to its own setup.
#
# Presence is not the whole check: `nvim` and `luac` must be the builds this hook installed,
# or the gates run against something CI never saw.
missing=()
if ! command -v nvim >/dev/null 2>&1; then
  missing+=("nvim")
elif [ "$(readlink -f "$(command -v nvim)")" != "$(readlink -f "${NVIM_PREFIX}/bin/nvim")" ]; then
  missing+=("nvim (PATH resolves to $(command -v nvim), not the managed ${NVIM_PREFIX})")
fi
if ! command -v luac >/dev/null 2>&1; then
  missing+=("luac")
elif ! luac_is_required_version; then
  missing+=("luac Lua ${LUA_VERSION} (PATH resolves to $(luac -v 2>&1 | head -1))")
fi
[ -d "${PLENARY_DIR}" ] || missing+=("plenary.nvim")
[ -d "${PROJECT_DIR}/node_modules" ] || missing+=("node_modules")

if [ "${#missing[@]}" -gt 0 ]; then
  log "ERROR: setup incomplete, still missing: ${missing[*]}"
  exit 1
fi

log "ready: npm run check / check:doc / test:lua / test:node are all runnable"
