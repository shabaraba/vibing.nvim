# Worktree management: redesign around Claude Code's native features

**Status:** investigation complete, design not started. Handoff for a fresh session.

**Branch:** `worktree-vibing-workspace` (already has the current `vibing-workspace-*`
skill-based worktree feature on it, merged with `main` as of `dfb1735`).

## The question

Does vibing.nvim need to run its own git-worktree lifecycle
(`scripts/vibing-workspace.mjs`, the `vibing-workspace-*` skills, `.vibing/workspace/<id>/meta.yaml`),
or can it lean on worktree/session features Claude Code itself already has, and just
"attach" to what Claude Code creates?

## Answer: partially yes, verified empirically this session

Do not trust an earlier same-day answer in this history that said these APIs don't
exist — that check was run against the **npm package** `@anthropic-ai/claude-agent-sdk`
pinned in `package.json` at the time (`^0.1.76`), which was two minor versions behind
latest (`0.3.206`) and genuinely lacks all of this. The **installed `claude` CLI binary**
(`claude --version` → `2.1.202`) is a separate artifact from the npm SDK package version
and already has the worktree features. Re-verify CLI version drift before trusting any
of this if picking the work back up much later.

### Verified facts (this session, via direct experimentation — not documentation)

1. `claude --worktree [name] -p ...` genuinely works. It creates a real git worktree at
   `<repo>/.claude/worktrees/<name>` with an auto-generated branch, and runs the headless
   session inside it. Confirmed with `git worktree list` after the call.
2. `--output-format stream-json --verbose` emits a `{"type":"system","subtype":"init","cwd":"<worktree path>","session_id":"..."}`
   event as the session starts. This is how you'd capture the created worktree's path.
3. **`--resume` does NOT restore the worktree cwd automatically.** Resuming a
   worktree-born session from the main repo directory puts you back in the main repo,
   not the worktree. The caller must keep tracking the cwd itself and pass it explicitly
   on every subsequent invocation — this is exactly what vibing.nvim's `working_dir`
   chat-frontmatter field + explicit `cwd` on `vim.system()` spawn already does today
   (see `lua/vibing/infrastructure/adapter/claude_cli.lua`,
   `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua`). **This part of
   the architecture does not need to change.**
4. In `@anthropic-ai/claude-agent-sdk@0.3.206`'s type defs (downloaded to a scratch dir,
   not installed in this repo — see below): `HookEvent` includes `WorktreeCreate`,
   `WorktreeRemove`, `CwdChanged` with typed `HookInput`/`HookSpecificOutput`.
   `sdk-tools.d.ts` has real `EnterWorktreeInput`/`ExitWorktreeInput`/`*Output` types.
   `listSessions(options?: ListSessionsOptions): Promise<SDKSessionInfo[]>` exists as a
   **standalone function that reads local JSONL transcripts** — it does not need an
   active `query()` session. `ListSessionsOptions` has `dir`, `includeWorktrees` (default
   `true`), `includeProgrammatic` (default `true`, includes `sdk-cli`-entrypoint sessions
   — i.e. vibing.nvim's own `claude -p` sessions would show up).
   `SDKSessionInfo` has `sessionId`, `gitBranch`, `cwd`, `summary`, `lastModified`, etc.
5. Not yet tested: whether `WorktreeCreate`/`WorktreeRemove` actually fire as
   `.claude/settings.json`-configured **command hooks** for a `claude -p` subprocess (the
   only kind of hook vibing.nvim can use, since it shells out to the real CLI rather than
   using the SDK's in-process `query()` — see point 6). This should work the same way
   `PreToolUse` already does via `lua/vibing/infrastructure/hooks/settings_generator.lua`
   - `--settings`, but wasn't empirically confirmed.
6. Confirmed separately (not re-verified this round, but solid from earlier in the same
   session): `options.hooks` passed programmatically to the SDK's `query()` only fires
   over a control-protocol channel that exists between the SDK's own spawned subprocess
   and the calling Node process. A manually-spawned `claude -p --resume <id>` (what
   vibing.nvim actually does) has no such channel — only `.claude/settings.json`-declared
   hooks fire for it. Relevant because it rules out ever using `options.hooks` directly;
   any hook usage must go through the existing settings-file mechanism.

### Important side-effect of this same session: the SDK dependency was just removed

`@anthropic-ai/claude-agent-sdk` was fully removed from `package.json` earlier in this
session (commit `7019901`) — it was only used by `bin/list-commands.ts` to power the
`/` skill-completion picker via `query().supportedCommands()`, which turned out to
silently drop any plugin whose `plugin.json` has `$schema`/`displayName` fields (see
commits `afa22cc`, `5881bdb`, `7064158` for that whole saga). `list-commands.ts` now
scans each installed plugin's `skills/` directory directly (SKILL.md frontmatter) plus a
hardcoded list of CLI built-ins, with no SDK dependency at all.

**This means:** if this redesign wants `listSessions()`, the SDK dependency needs to be
**reintroduced**, deliberately pinned to something like `^0.3.x` (not `^0.1.x` again —
that's what caused the version-drift bug this session spent a long time debugging), and
scoped to exactly this one use. Reimplementing `listSessions()`'s JSONL-parsing +
worktree-path-matching logic by hand was considered and rejected as more fragile than it
looks: `~/.claude/projects/<encoded-cwd>/*.jsonl` files start with entries like
`{"type":"queue-operation",...}`, not clean session metadata, and mapping git worktree
paths to their corresponding project directories requires knowing Anthropic's path-encoding
scheme, which could change without notice. This is unlike the `list-commands.ts` rewrite,
where `SKILL.md` frontmatter is a stable, simple, already-understood format — that
comparison is why one got reimplemented locally and the other is flagged as "worth an SDK
dependency instead."

## What this means for the actual redesign (not yet decided)

| Piece                                                                      | Today                                                                     | Proposed                                                                                                                                                  |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Create/remove the git worktree                                             | `scripts/vibing-workspace.mjs` runs `git worktree add`/`remove` itself    | Pass `--worktree [name]` on the first (non-`--resume`) `claude -p` call instead                                                                           |
| Capture the worktree path                                                  | N/A (vibing.nvim already knows it, since it made the path)                | Parse the `cwd` field off the `system`/`init` stream-json event                                                                                           |
| Stay attached across turns                                                 | `working_dir` chat frontmatter + explicit `cwd` on every subsequent spawn | **No change** — same mechanism works regardless of who created the worktree                                                                               |
| Lifecycle bookkeeping hooks (if wanted)                                    | N/A                                                                       | `WorktreeCreate`/`WorktreeRemove` via the existing `.claude/settings.json` + `SettingsGenerator` pattern (needs empirical confirmation, see fact 5 above) |
| Discover pre-existing worktrees/sessions not created via vibing.nvim       | Impossible today                                                          | `listSessions({dir: cwd, includeWorktrees: true})` — requires reintroducing the SDK dependency, scoped narrowly                                           |
| Task-level metadata (`meta.yaml`, `plan.md`, "what is this workspace for") | Custom, in `scripts/vibing-workspace.mjs`                                 | **No Claude Code equivalent exists.** Stays custom no matter which direction is chosen.                                                                   |

## Other loose ends found this session, not yet fixed

- `mcp-server/src/handlers/chat.ts`'s `handleChatWorktree` (backing the `nvim_chat_worktree`
  MCP tool) still calls `:VibingChatWorktree ...`, a Neovim command that was removed from
  this branch in favor of the `vibing-workspace-*` skills (commit `9257d12`, "remove
  VibingChatWorktree"). This handler is currently dead/broken. Whatever direction this
  redesign takes, this needs fixing or removing.
- `lua/vibing/infrastructure/permissions/can_use_tool.lua:41-42` lists `EnterWorktree` and
  `ExitWorktree` in `INTERNAL_TOOLS` (always-allowed). An earlier pass in this same session
  flagged this as "speculative dead code based on a wrong premise" — **that was wrong**,
  said before the CLI-vs-npm-package version distinction was understood. These probably
  _are_ real tool names the installed CLI can invoke (see verified fact 4). Don't re-remove
  them without checking the currently-installed CLI's actual behavior first.

## Open questions for whoever picks this up

1. Should `vibing-workspace-*` skills keep their current UX/command surface and just swap
   their internal implementation (skills still exist, `scripts/vibing-workspace.mjs`
   changes what it does under the hood), or does the skill surface itself change?
2. Does `WorktreeCreate`/`WorktreeRemove` actually fire via `.claude/settings.json` for a
   `claude -p` subprocess? Test this before designing around it.
3. `isolation: 'worktree'` on the `Agent` tool (used by _this Claude session itself_ when
   spawning sub-agents) and `bgIsolation` in the SDK's settings-schema `worktree` config
   block are a related but distinct concept from what a vibing.nvim _chat_ needs — worth
   explicitly scoping which of these the redesign actually touches.
4. If `listSessions()` comes back as a dependency: does it belong in `bin/` (Node backend,
   same place `list-commands.ts` lives) or does the workspace-listing skill just shell out
   to it directly? Given `scripts/vibing-workspace.mjs` is already a standalone Node
   script invoked by the skills, that's probably the natural integration point.

## Key files for orientation

- `lua/vibing/infrastructure/adapter/claude_cli.lua`,
  `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua` — how vibing.nvim
  spawns `claude -p --resume ...`; this is where a `--worktree` flag would get added on
  first-message calls
- `lua/vibing/infrastructure/hooks/settings_generator.lua` — the existing
  `.claude/settings.json`-generation mechanism for command hooks (`--settings` flag)
- `scripts/vibing-workspace.mjs` — current custom worktree create/list/done/enter logic
- `skills/vibing-workspace/SKILL.md` + `skills/vibing-workspace-{create,enter,done,list}/SKILL.md`
- `bin/lib/plugin-loader.ts`, `bin/list-commands.ts` — this session's unrelated SDK-removal
  refactor (context for why the SDK isn't a dependency right now, not part of the worktree
  work itself)
- `docs/superpowers/plans/2026-07-03-vibing-workspace.md`,
  `docs/superpowers/specs/2026-07-03-vibing-workspace-design.md` — the design/plan docs for
  the _current_ (pre-redesign) `vibing-workspace-*` feature this would be replacing parts of

## Suggested next step

Use the `brainstorming` skill to turn the "what changes, what doesn't" table above into an
actual design, then `writing-plans` for the implementation breakdown. The open questions
above are exactly the kind of thing brainstorming should resolve before code gets written.
