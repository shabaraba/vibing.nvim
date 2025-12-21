# Claude Code Skills

This directory contains skills for Claude Code to provide specialized knowledge and workflows.

## Available Skills

### git-remote-workflow

**Location:** `.claude/skills/git-remote-workflow/SKILL.md`

Comprehensive Git workflow for Claude Code on the web environment with:

- **Branch Management:** Naming validation (`claude/*-<sessionId>` pattern), branch conversion
- **Push Operations:** Automatic retry with exponential backoff, force push handling
- **PR Creation:** GitHub API integration (no `gh` CLI dependency), multiple PR creation
- **Complete Workflows:** Feature development, review comment resolution, multi-PR workflows
- **Troubleshooting:** Common issues and solutions
- **Environment Detection:** Automatic detection of remote environment

**When activated:** Automatically when working with Git in Claude Code on the web (`CLAUDE_CODE_REMOTE=true`)

**Allowed tools:** Bash, Read, Grep

**Coverage:**

- Git push with retry logic
- Pull request creation via GitHub API
- Branch naming compliance
- Multi-PR workflows
- Error handling and debugging

## How Skills Work

Skills are directories containing a `SKILL.md` file with YAML frontmatter:

```yaml
---
name: skill-name
description: What this skill does and when to use it
allowed-tools: Bash, Read, Grep # Optional
---
# Skill Instructions

Clear, step-by-step guidance...
```

**Key components:**

- `name`: Lowercase, numbers, hyphens only (max 64 chars)
- `description`: Brief description for Claude to discover when to use (max 1024 chars)
- `allowed-tools`: Optional list of tools this skill can use without asking permission

Skills are activated automatically by Claude based on:

- Environment detection (`CLAUDE_CODE_REMOTE=true`)
- User requests matching the description
- Current task context

## Creating New Skills

To create a new skill:

1. Create a directory in `.claude/skills/`:

   ```bash
   mkdir -p .claude/skills/my-skill
   ```

2. Create `SKILL.md` with YAML frontmatter:

   ```yaml
   ---
   name: my-skill
   description: What it does and when to use it
   ---

   # My Skill

   ## Instructions
   Step-by-step guidance for Claude

   ## Examples
   Concrete usage examples
   ```

3. Optionally add support files:

   ```text
   my-skill/
   ├── SKILL.md (required)
   ├── reference.md (optional)
   └── scripts/
       └── helper.py (optional)
   ```

4. Update this README with the new skill

For detailed guidance, see [Claude Code Skills Documentation](https://docs.claude.com/ja/docs/agents-and-tools/agent-skills).
