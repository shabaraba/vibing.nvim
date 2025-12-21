# Claude Code Skills

This directory contains skills for Claude Code to provide specialized knowledge and workflows.

## Available Skills

### git-push-remote.md

Handles Git push operations in Claude Code on the web environment with:
- Branch naming validation (`claude/*-<sessionId>` pattern)
- Automatic retry with exponential backoff
- Environment detection
- Helper functions for push operations

**When activated:** Automatically in Claude Code on the web (`CLAUDE_CODE_REMOTE=true`)

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
