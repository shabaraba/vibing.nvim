# Claude Code on the Web

Only two things must be known without reading anything:

- **Branch names MUST start with `claude/` and end with a matching session ID**
  (`claude/feature-name-abc123`). A non-compliant branch fails the push with HTTP 403.
- **Retry pushes with exponential backoff** (2s, 4s, 8s, 16s), up to 4 attempts — network
  operations fail transiently there.

The full GitHub workflow (REST API instead of `gh`, PR creation/update, review-comment resolution)
is the `github-flow-for-claude-on-web` skill. The `SessionStart` hook that installs Neovim, plenary
and `lua5.3` so the CI gates can run in the container at all — and the five decisions inside it —
is `handbook/web-container-setup.md`. Taking a screenshot from the container is the
`remote-screenshot` skill.
