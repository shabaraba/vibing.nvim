# Claude Code on the Web: Container Setup and Git Push

Moved out of `.claude/rules/web-workflow.md`. The GitHub half is the
`github-flow-for-claude-on-web` skill; this file is the SessionStart hook that makes the CI gates
runnable in the container at all.

## Environment Setup (SessionStart Hook)

The web container ships node and git but **neither Neovim nor a Lua compiler**, so four of the
five CI gates cannot start there: `test:lua`, `test:e2e` and `check:doc` invoke `nvim`, and
`check` invokes `luac`. `.claude/hooks/session-start.sh` installs them —
Neovim `stable` to `/opt/nvim`, plenary.nvim, `lua5.3`, `npm install` — mirroring the
corresponding steps of `.github/workflows/ci.yml` so a web session fails and passes on the same
things CI does. It is registered as a `SessionStart` hook in `.claude/settings.json`.

Five things about it are decisions rather than details:

- **It no-ops unless `CLAUDE_CODE_REMOTE=true`.** A local machine has the developer's own
  Neovim, and writing to `/opt` and `/usr/local` there is never what is wanted.
- **It is synchronous.** The first thing a web session usually does is run the suite; an async
  hook would let that start against a half-installed environment.
- **It verifies at the end and exits non-zero on anything missing.** A hook that reports
  success over a broken environment makes the next failure look like the repository's, which is
  the whole failure it exists to prevent. For the same reason its progress output goes to
  **stderr**: a `SessionStart` hook's stdout is prepended to the session as context.
- **It checks which `nvim` and `luac` it got, not merely that one exists.** Both are keyed on
  the build the hook itself manages, because a tool the image happens to ship would otherwise
  decide what the gates run against. `luac` is the sharp case: 5.4 compiles syntax 5.3 rejects
  (`local x <const> = 1`), so a container whose bare `luac` is 5.4 would let `npm run check`
  pass here and fail in CI.
- **It installs Node dependencies with `npm ci`, like CI.** `npm install` **rewrites
  `package-lock.json`** when it disagrees with `package.json`, which both hides drift CI would
  reject and leaves a working-tree change the per-turn git tree snapshot reports under
  `### Modified Files`. The container-cache benefit that argued for `npm install` is kept
  another way: the hook stamps the lockfile's digest inside `node_modules` and skips the
  install entirely while it still matches.

`plenary.nvim` goes under `vim.fn.stdpath("data")` (honouring `XDG_DATA_HOME`), because that is
where `tests/minimal_init.lua` looks for it.

The `stable` Neovim tag publishes no checksum of its own, so certificate verification on the
HTTPS fetch is the integrity boundary; the tarball is unpacked to a staging directory and
smoke-tested before it becomes `/opt/nvim`, so a truncated download cannot leave a prefix that
later runs mistake for a good install. Set `VIBING_NVIM_SHA256` alongside a pinned
`VIBING_NVIM_VERSION` to check a digest.

**The hook has no automated test, and that is deliberate rather than an oversight.** It installs
system packages into a throwaway container, so exercising it means being in one. It is verified
by running it against a fully torn-down container and reading the result — do that after
changing it, rather than looking for a spec that does not exist.

## Git Push Requirements

**Branch Naming:** branch names MUST start with `claude/` and end with a matching session ID
(e.g. `claude/feature-name-abc123`). Pushing to a non-compliant branch fails with HTTP 403.

**Retry Logic:** network operations may fail transiently — always retry pushes with exponential
backoff (2s, 4s, 8s, 16s), up to 4 attempts.

```bash
# Create compliant branch. No fallback: a made-up suffix does not match the
# session, so the push would fail with 403 rather than land somewhere odd.
git checkout -b "claude/my-feature-${CLAUDE_SESSION_ID:?CLAUDE_SESSION_ID is required}"

# Push with retry
for i in 0 1 2 3; do
  [ $i -gt 0 ] && sleep $((2 ** i))
  git push -u origin "$(git branch --show-current)" && break
done
```

`.claude/skills/github-flow-for-claude-on-web/SKILL.md` provides branch name validation/conversion,
push retry with exponential backoff and safe force-push handling, PR creation/update via the GitHub
API (no `gh` CLI required, including multi-line descriptions), and complete workflows (feature →
PR, review-comment resolution, multi-PR sessions). It auto-detects Claude Code on the web via
`CLAUDE_CODE_REMOTE=true` and applies environment-specific logic accordingly.
