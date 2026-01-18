# Claude Code on the Web

When developing with Claude Code on the web, there are specific Git push constraints that require special handling.

## Git Push Requirements

**Branch Naming:**

- Branch names MUST start with `claude/`
- Branch names MUST end with a matching session ID
- Example: `claude/feature-name-abc123`
- Pushing to non-compliant branches will fail with HTTP 403

**Retry Logic:**

- Network operations may experience transient failures
- Always use exponential backoff retry (2s, 4s, 8s, 16s)
- Maximum 4 retry attempts recommended

## Using the Git Workflow Skill

A comprehensive skill is available at `.claude/skills/git-remote-workflow/SKILL.md` that provides:

**Branch Management:**

- Branch name validation and conversion
- Pattern compliance checking (`claude/*-<sessionId>`)

**Push Operations:**

- Automatic retry with exponential backoff
- Force push handling with safety checks

**Pull Request Creation:**

- GitHub API integration (no `gh` CLI required)
- Multi-line PR descriptions with proper formatting
- Multiple PR creation in one session
- PR update capabilities

**Complete Workflows:**

- Feature development to PR creation
- Review comment resolution
- Multi-PR workflows

**Environment Detection:**

- Automatic detection of Claude Code on the web (`CLAUDE_CODE_REMOTE=true`)
- Environment-specific logic application

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

See `.claude/skills/git-remote-workflow/SKILL.md` for complete documentation, workflows, and troubleshooting.
