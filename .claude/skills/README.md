# Claude Code Skills (development-only)

Skills in this directory are for **developing this repository**. They are not distributed —
the ones users get are `claude-plugin/skills/`. Each is read on demand, so put procedures and
long-form reasoning here rather than in `.claude/rules/`, which is loaded into every request.

| Skill                           | Invoke when                                                                     |
| ------------------------------- | ------------------------------------------------------------------------------- |
| `self-testing`                  | Writing or debugging an E2E spec; the helper API and the child-Neovim traps     |
| `test-design`                   | Designing scenarios before writing tests                                        |
| `ci-gates`                      | Touching `package.json` scripts, CI, `scripts/check-help.lua`, or a gate's test |
| `github-flow-for-claude-on-web` | Any GitHub operation from the web container (REST API, never `gh`)              |
| `remote-screenshot`             | Showing what a UI change looks like from the web container                      |

## Structure

A skill is a directory holding `SKILL.md` with YAML frontmatter:

```yaml
---
name: skill-name # lowercase, digits, hyphens; max 64 chars
description: What it does and when to use it # max 1024 chars — this is what Claude matches on
allowed-tools: Bash, Read, Grep # optional
---
```

The `description` is the only part loaded up front, so it has to say **when** to reach for the
skill, not just what it contains. Support files (`reference.md`, `scripts/`) sit beside `SKILL.md`
and are read only if the skill says to.

When adding one, decide first which reader it is for: `claude-plugin/skills/` reaches users via
`--plugin-dir`, `.claude/skills/` does not leave this repository. Then add a row above.

See [Agent Skills](https://docs.claude.com/ja/docs/agents-and-tools/agent-skills).
