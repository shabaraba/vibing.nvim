# Claude Code Skills

This directory contains skills for Claude Code to provide specialized knowledge and workflows.

## Available Skills

### git-remote-workflow.md

Comprehensive Git workflow for Claude Code on the web environment with:
- **Branch Management:** Naming validation (`claude/*-<sessionId>` pattern), branch conversion
- **Push Operations:** Automatic retry with exponential backoff, force push handling
- **PR Creation:** GitHub API integration (no `gh` CLI dependency), multiple PR creation
- **Complete Workflows:** Feature development, review comment resolution, multi-PR workflows
- **Troubleshooting:** Common issues and solutions
- **Environment Detection:** Automatic detection of remote environment

**When activated:** Automatically in Claude Code on the web (`CLAUDE_CODE_REMOTE=true`)

**Coverage:**
- Git push with retry logic
- Pull request creation via GitHub API
- Branch naming compliance
- Multi-PR workflows
- Error handling and debugging

**Usage:** Reference this skill when performing Git operations in remote Claude Code sessions.

## How Skills Work

Skills are markdown files that provide Claude Code with:
1. Context-specific knowledge
2. Code snippets and patterns
3. Best practices and workflows
4. Environment-specific constraints

Skills are activated either:
- Automatically based on environment detection
- Manually by the user invoking them
- By Claude Code when relevant to the current task

## Creating New Skills

To create a new skill:

1. Create a markdown file in `.claude/skills/`
2. Include clear documentation with:
   - When to use the skill
   - Code examples
   - Common issues and solutions
   - Integration examples

3. Update this README with the new skill

Example structure:

```markdown
# Skill Name

Description of what this skill provides.

## When to Use

Explain when this skill should be activated.

## Usage

Provide code examples and patterns.

## Common Issues

List common problems and solutions.
```
