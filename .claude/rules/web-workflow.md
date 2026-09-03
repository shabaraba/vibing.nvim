# Claude Code on the Web

When developing with Claude Code on the web, there are specific Git push constraints that require
special handling.

## Environment Setup (SessionStart Hook)

The web container ships node and git but **neither Neovim nor a Lua compiler**, so four of the
five CI gates cannot start there: `test:lua`, `test:e2e` and `check:doc` invoke `nvim`, and
`check` invokes `luac`. `.claude/hooks/session-start.sh` installs them —
Neovim `stable` to `/opt/nvim`, plenary.nvim, `lua5.3`, `npm install` — mirroring the
corresponding steps of `.github/workflows/ci.yml` so a web session fails and passes on the same
things CI does. It is registered as a `SessionStart` hook in `.claude/settings.json`.

Three things about it are decisions rather than details:

- **It no-ops unless `CLAUDE_CODE_REMOTE=true`.** A local machine has the developer's own
  Neovim, and writing to `/opt` and `/usr/local` there is never what is wanted.
- **It is synchronous.** The first thing a web session usually does is run the suite; an async
  hook would let that start against a half-installed environment.
- **It verifies at the end and exits non-zero on anything missing.** A hook that reports
  success over a broken environment makes the next failure look like the repository's, which is
  the whole failure it exists to prevent. For the same reason its progress output goes to
  **stderr**: a `SessionStart` hook's stdout is prepended to the session as context.

`plenary.nvim` goes under `vim.fn.stdpath("data")` (honouring `XDG_DATA_HOME`), because that is
where `tests/minimal_init.lua` looks for it.

## Git Push Requirements

**Branch Naming:** branch names MUST start with `claude/` and end with a matching session ID
(e.g. `claude/feature-name-abc123`). Pushing to a non-compliant branch fails with HTTP 403.

**Retry Logic:** network operations may fail transiently — always retry pushes with exponential
backoff (2s, 4s, 8s, 16s), up to 4 attempts.

## Using the Git Workflow Skill

`.claude/skills/git-remote-workflow/SKILL.md` provides branch name validation/conversion, push
retry with exponential backoff and safe force-push handling, PR creation/update via the GitHub API
(no `gh` CLI required, including multi-line descriptions), and complete workflows (feature → PR,
review-comment resolution, multi-PR sessions). It auto-detects Claude Code on the web via
`CLAUDE_CODE_REMOTE=true` and applies environment-specific logic accordingly.

## Quick Reference

```bash
# Create compliant branch
git checkout -b "claude/my-feature-${CLAUDE_SESSION_ID:-9GOGf}"

# Push with retry
for i in 0 1 2 3; do
  [ $i -gt 0 ] && sleep $((2 ** i))
  git push -u origin "$(git branch --show-current)" && break
done

# Create PR via GitHub API
curl -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/owner/repo/pulls" \
  -d '{"title":"My PR","head":"claude/branch-abc","base":"main","body":"Description"}'
```

See `.claude/skills/git-remote-workflow/SKILL.md` for complete documentation, workflows, and
troubleshooting.
