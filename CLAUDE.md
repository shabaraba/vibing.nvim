# CLAUDE.md

## Project Overview

vibing.nvim is a Neovim plugin that provides a Claude chat inside Neovim by spawning the `claude`
CLI directly (`claude -p --output-format stream-json`) and parsing its stream. There is no Node.js
agent wrapper process; the Node side is only the MCP server and two hook scripts. Codex, Copilot
and Grok CLI backends are also supported. See `.claude/rules/architecture.md`.

## Commands

```bash
npm install && ./build.sh   # dependencies, then the MCP server
npm test                    # test:lua + test:node
npm run check               # Lua syntax; see also check:doc for doc/*.txt
npm run lint                # eslint only; lint:md, format and format:check are separate
```

`test:e2e` and `test:eval` spend real tokens and are deliberately outside `npm test`. Every script
is in `package.json`; for manual testing, load the plugin and run `:VibingChat`.

## Where Documentation Lives

**`.claude/rules/*.md` is loaded into every request.** So it holds only two kinds of thing:
invariants you would otherwise break, and this map. Reasons, measurements and rejected
alternatives belong in `handbook/`; procedures belong in a skill. Both are read on demand.
If you add a paragraph to `.claude/rules/` explaining _why_, it is in the wrong file.

| `.claude/rules/`      | Invariants for                                                      |
| --------------------- | ------------------------------------------------------------------- |
| `architecture.md`     | CLI/hook protocol, backend seams, plugin dirs, diffs, orchestration |
| `permissions.md`      | Evaluation order, per-chat approval state, delegated approval       |
| `mcp-integration.md`  | Tool prefixes, `rpc_port`, window/chat addressing                   |
| `features.md`         | Usage limits, subagent output, AskUserQuestion, timestamps, dap     |
| `configuration.md`    | Pointer to the option reference                                     |
| `self-development.md` | Three mistakes made repeatedly when developing this repo            |
| `self-testing.md`     | What only `test:e2e` may run; the 3-try rule                        |
| `web-workflow.md`     | Branch naming and push retry on Claude Code for the web             |

| `handbook/` (on demand)               | Contents                                                |
| ------------------------------------- | ------------------------------------------------------- |
| `configuration.md`                    | Every `setup()` field, defaults, granular rule examples |
| `architecture/module-map.md`          | Per-directory listing, key entry points, adapter split  |
| `architecture/cli-integration.md`     | Hook protocol, backend seams, per-CLI measurements      |
| `architecture/permissions.md`         | Evaluation order, Permission Builder, approval UI, #667 |
| `architecture/lightweight-calls.md`   | How each backend restricts utility calls                |
| `architecture/plugin-and-commands.md` | `--plugin-dir`, slash command discovery, startup cost   |
| `architecture/per-request-diffs.md`   | git tree snapshot, overlap guard, fallback routing      |
| `architecture/chat-lineage.md`        | Concurrency, fork, handoff, subagent chat               |
| `architecture/orchestration.md`       | Notification state machine, queue, tree operations      |
| `architecture/session-persistence.md` | The `working_dir` git-root boundary                     |
| `features/usage-limits.md`            | Auto-resume, scheduled requests, retry budget           |
| `features/chat-ui.md`                 | Subagent output, timestamps, AskUserQuestion            |
| `features/editor-integration.md`      | Code Tour, nvim-dap analysis                            |
| `mcp-tools.md`                        | The MCP tool catalogue and its non-obvious behaviour    |
| `web-container-setup.md`              | The `SessionStart` hook for Claude Code on the web      |

| `.claude/skills/` (on demand)   | Invoke when                                         |
| ------------------------------- | --------------------------------------------------- |
| `self-testing`                  | Writing or debugging an E2E spec                    |
| `test-design`                   | Designing scenarios before writing tests            |
| `ci-gates`                      | Touching package.json scripts, CI, or a gate's test |
| `github-flow-for-claude-on-web` | Any GitHub operation from the web container         |
| `remote-screenshot`             | Showing a UI change from the web container          |

User-facing command, slash command and keybinding documentation is `doc/vibing.txt` — the one
place, kept honest by `npm run check:doc`. Do not restate it in `.claude/rules/`.

## Repository Layout

Everything distributed to Claude Code lives under **`claude-plugin/`**. The repository root is the
marketplace root; the plugin root is one level below it. The normal path is no longer the
marketplace, though: `cli_command_builder` passes `claude-plugin/` to the CLI per session with
`--plugin-dir` (#618). `marketplace.json` remains only for a manual `claude plugin install`.

| Path                                       | Contents                                          |
| ------------------------------------------ | ------------------------------------------------- |
| `.claude-plugin/marketplace.json`          | marketplace definition, `source: ./claude-plugin` |
| `claude-plugin/.claude-plugin/plugin.json` | plugin definition; `${CLAUDE_PLUGIN_ROOT}` parent |
| `claude-plugin/{agents,skills}/`           | **distributed** subagents and skills              |
| `claude-plugin/mcp-server/`                | the distributed MCP server                        |
| `.claude/{skills,commands,rules}/`         | **for developing this repo**; not distributed     |

When adding a skill, the directory is decided by which reader it is for. The directory is not named
`plugin/` because that is a Neovim reserved name: `plugin/**/*.lua` on the runtimepath is sourced
at every startup (`:h load-plugins`), so a tree containing `node_modules` there is walked every
time Neovim starts.

## Development Rules

- **Test fixtures and scaffolds go under `tests/`** (`tests/fixtures/`, `tests/e2e/`,
  `tests/lua/`), never as `test-*/` at the repository root.

## Key Constants

`lua/vibing/core/constants/tools.lua` is the single definition of tool names. `config.lua` and
`can_use_tool.lua` reference it rather than re-listing values.

- **`VALID_TOOLS`** — names writable in permission settings; used to warn about unknown ones.
- **`DEFAULT_ALLOWED_TOOLS`** — the default `permissions.allow`. Not derived as a difference from
  `VALID_TOOLS` (see the comment in that file).
- **`ALWAYS_ALLOWED_TOOLS`** — the floor that stays allowed regardless of `allow`, unless the user
  puts the tool in `ask` / `deny`. The criterion is "read-only built-in that creates, updates or
  deletes no file" (`Read` / `Glob` / `Grep`). Removing one from `DEFAULT_ALLOWED_TOOLS` does not
  disallow it while it is still here.
- **`INTERNAL_TOOLS`** — harness-internal, side-effect-free control tools (`ToolSearch`,
  `TodoWrite`, `ReportFindings`, `ScheduleWakeup`). Always allowed, ahead of `ALWAYS_ALLOWED_TOOLS`
  in `can_use_tool.lua`, so not even `ask` / `deny` applies. No `VALID_TOOLS` entry needed; the
  check reads `INTERNAL_TOOLS_MAP`.
- Adding a tool: allowed by default → both `VALID_TOOLS` and `DEFAULT_ALLOWED_TOOLS`; not allowed
  by default (like `Bash`) → `VALID_TOOLS` only.
