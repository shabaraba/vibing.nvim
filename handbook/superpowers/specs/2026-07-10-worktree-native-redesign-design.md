# Worktree management redesign: design

**Status:** design approved, ready for implementation planning.

**Branch:** `worktree-vibing-workspace`.

**Predecessor doc:** `docs/superpowers/specs/2026-07-10-worktree-native-redesign.md` — the
investigation handoff that prompted this design. Read that first for the empirical findings
(CLI vs npm SDK version drift, `--worktree` flag behavior, `--resume` cwd behavior) that this
design builds on. This design supersedes that doc's open questions; where the two disagree,
this doc wins.

## Motivation

vibing.nvim currently runs its own git-worktree lifecycle (`scripts/vibing-workspace.mjs` +
the `vibing-workspace-*` skills + `.vibing/workspace/<id>/meta.yaml` + `plan.md`). This grew out
of a time when Claude Code had no worktree-awareness of its own. It now does — `git worktree`
itself was always available, and nothing about our custom bookkeeping (`meta.yaml`, `plan.md`,
the monotonic counter, `active`/`done` status tracking) is something only Claude Code could
provide. The redesign's goal is to stop maintaining that bookkeeping and let the following do
the work instead:

- **git itself** — `git worktree list`/`add`/`remove` are the source of truth for what
  worktrees exist. No parallel JSON/YAML state.
- **The chat file's own `working_dir` frontmatter** — already tracks which directory a given
  chat session operates in; this mechanism is unchanged by this redesign and already solves
  "stay attached across turns."
- **Natural-language interaction** — creating, listing, attaching to, and finishing a worktree
  all become things the user asks Claude for in conversation, backed by Bash + Edit tool calls
  documented in a skill, not a bespoke UI or command surface.

An earlier framing of this work considered delegating worktree _creation_ to the `claude
--worktree` CLI flag and worktree _discovery_ to the Agent SDK's `listSessions()` API. Both were
explicitly rejected during design (see "Rejected approaches" below) in favor of plain `git`
commands — the CLI's native features turned out to add cost (an extra throwaway subprocess,
lost control over branch/path naming) without a corresponding benefit once the actual
bookkeeping being removed was correctly scoped to `meta.yaml`/`plan.md`, not `git worktree add`
itself.

## What's removed

- `scripts/vibing-workspace.mjs`
- `skills/vibing-workspace/`, `skills/vibing-workspace-create/`, `skills/vibing-workspace-enter/`,
  `skills/vibing-workspace-done/`, `skills/vibing-workspace-list/` (5 skill directories)
- `.vibing/workspace/<id>/meta.yaml`, `.vibing/workspace/<id>/plan.md`, and the global `.counter`
  file — no replacement bookkeeping file of any kind
- `mcp-server/src/handlers/chat.ts`'s `handleChatWorktree` function, its registration in
  `mcp-server/src/tools/chat.ts` and `mcp-server/src/handlers/index.ts` (the `nvim_chat_worktree`
  MCP tool). This handler already called the removed `:VibingChatWorktree` Neovim command and was
  dead code before this redesign; it is deleted outright, not repaired.

## What's added

- One skill (working name: `vibing-worktree`) bundled with the plugin under `skills/`, replacing
  the 5 removed skills. It documents four natural-language-triggered recipes — list, create,
  attach, finish — as Bash/Edit tool call sequences (see "Data flow" below). It does not shell out
  to any bespoke helper script; every step is a direct `git` command or an `Edit` on the chat
  file's own frontmatter.
- One line appended to the system prompt vibing.nvim already builds per-request (in
  `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua`, via the same
  `--append-system-prompt` mechanism the `language` option already uses): instructing Claude that
  worktrees created for isolated work belong under `.vibing/worktrees/<branch-name>/`.

## What's unchanged

- The `working_dir` chat-frontmatter field and the explicit `cwd` passed to every `vim.system()`
  spawn in `lua/vibing/infrastructure/adapter/claude_cli.lua`. This is the mechanism that keeps a
  chat session attached to its worktree across turns, and it already works regardless of how the
  worktree was created or discovered.
- `lua/vibing/infrastructure/permissions/can_use_tool.lua`'s `EnterWorktree`/`ExitWorktree` entries
  in `INTERNAL_TOOLS` — these back the `Agent` tool's own sub-agent worktree isolation
  (`isolation: 'worktree'`), a distinct concept from chat-level worktrees. Out of scope; do not
  touch.

## Rejected approaches (and why)

**Delegating worktree creation to `claude --worktree <name> -p ...`.** This would create the
worktree via a throwaway `claude` subprocess whose only purpose is provisioning a directory: the
current conversation's own session is what actually continues in it afterward (via `working_dir`

- `--resume`), so the throwaway session is pure overhead — an extra process spawn, extra latency,
  extra token cost, for a session that's immediately abandoned. It also cedes control over the
  worktree's path (fixed at `.claude/worktrees/<name>`) and branch-naming (CLI-auto-generated) for
  no discovery benefit — `git worktree list` finds worktrees regardless of which command created
  them. Plain `git worktree add -b <branch> <path>`, run directly via the Bash tool, achieves the
  same end state with none of the overhead.

**Using the Agent SDK's `listSessions()` for worktree/session discovery.** This was the original
plan for the "list what worktrees exist" flow, but reintroducing the SDK dependency (removed from
`package.json` in commit `7019901`, earlier in the same investigation that produced this redesign)
is unjustified once the actual requirement is examined: `git worktree list --porcelain` already
enumerates every worktree registered against the repo — including ones created outside
vibing.nvim entirely (a bare `git worktree add`, or a manually-run `claude --worktree`) — without
any dependency beyond git, which is already required. The one thing `listSessions()` would add is
a human-readable summary of each worktree's most recent Claude conversation and a resumable
`session_id`. But per-worktree session resumption was never actually part of the workspace model
being replaced: each chat _file_ carries its own independent `session_id` in frontmatter, and the
old `vibing-workspace-enter` skill only ever repointed a chat's `working_dir`, never resumed "the
workspace's session" as a single thing. So there is no existing behavior this would preserve — the
loss is limited to a nice-to-have summary line, which `git log -1 --format=%s <branch>` (the
worktree branch's latest commit message) approximates well enough via plain git.

## Directory layout

```text
<git root>/.vibing/worktrees/
├── fix-auth-session-bug/     # the git worktree itself — no nesting, no meta.yaml, no plan.md
└── refactor-permission-ui/
```

No counter prefix, no `active`/`done` split, no `worktree/` subdirectory nesting. A worktree's
existence on disk _is_ its entire state. Git itself already refuses to check out a branch that's
open in another worktree, so name collisions between concurrently-active worktrees are impossible
by construction; reusing a branch name after its worktree was removed is harmless directory-name
reuse, not a collision.

## Data flow

All four flows are natural-language-triggered, mid-conversation, in any chat (new or existing) —
there is no separate UI, picker, or slash command surface. `nvim_get_info` (vibing-nvim MCP) is
how Claude learns its own chat file's path in order to edit its own frontmatter; this is the same
pattern the removed skills already used to record `chat_files`.

**List** — user asks e.g. "what worktrees exist?"

1. Claude runs `git worktree list --porcelain` via Bash.
2. Optionally, for each entry, `git log -1 --format=%s <branch>` for a one-line hint of what was
   last done there.
3. Presents the results conversationally.

**Create** — user asks e.g. "split this off into its own worktree"

1. Claude derives a branch name from the conversation's context.
2. Claude runs `git worktree add -b <branch> .vibing/worktrees/<branch>` via Bash.
3. Claude calls `nvim_get_info` to get its own chat file's path.
4. Claude edits that file's `working_dir` frontmatter field to the new worktree path via the
   `Edit` tool.
5. No new chat buffer is opened — the current conversation continues, and its next turn already
   runs with the new `working_dir` (existing `--resume` + explicit `cwd` mechanism, unchanged).

**Attach** — user asks e.g. "what worktrees are there? — let's go into the auth one" (works
identically whether this is a brand-new chat's first exchange or mid-conversation in an existing
chat)

1. Same as **List**, to surface candidates.
2. User picks one in conversation.
3. Same as **Create** steps 3-4: Claude finds its own chat file via `nvim_get_info` and edits its
   `working_dir` frontmatter to the chosen worktree's path.

**Finish** — user asks e.g. "clean up this worktree"

1. Claude runs `git worktree remove <path>` via Bash — **never with `--force`**. If git refuses
   because of uncommitted changes, that error is surfaced to the user verbatim so they can decide
   (commit/stash/discard) rather than silently losing work.
2. If the removed path was the current chat's own `working_dir`, Claude clears that frontmatter
   field (reverting to the main repo root) once removal succeeds — continuing to point at a
   deleted directory would break the next turn's spawn.

## Error handling

- `git worktree remove` failing on uncommitted changes: surfaced verbatim, no `--force` ever used.
- `git worktree add` failing because the branch is already checked out elsewhere: surfaced
  verbatim.
- vibing-nvim MCP server not connected (Claude can't call `nvim_get_info` to learn its own chat
  file path): the worktree-level git operations (create/list/finish) still work since they don't
  depend on MCP, but the frontmatter edit step (attach) can't happen automatically. Claude tells
  the user the worktree is ready at `<path>` and that `working_dir` needs to be set by hand. This
  mirrors the graceful degradation the removed `vibing-workspace-create`/`-enter` skills already
  had for the same MCP-unavailable case.

## Testing

Rewrite `docs/e2e-tests/08-worktree-integration.md` to cover the four flows above as E2E
scenarios, in particular:

- Finish is refused (and the refusal surfaces to the user) when the worktree has uncommitted
  changes.
- Attach correctly rewrites `working_dir` in the current chat file's frontmatter and subsequent
  turns run with the new `cwd`.
- The MCP-unavailable fallback for attach/create degrades as described above rather than
  erroring.

## Files requiring updates beyond the additions/removals above

- `lua/vibing/core/utils/mote/context.lua`, `lua/vibing/core/utils/mote/moteignore.lua` — both
  currently pattern-match the old `.vibing/workspace/{active,done}/<id>/worktree` path (used to
  name/detect mote contexts per-worktree). Update to match
  `.vibing/worktrees/<branch-name>` instead.
- `.claude/rules/commands-reference.md`, `.claude/rules/architecture.md`,
  `.claude/rules/self-testing.md`, `.claude/rules/self-development.md`, `README.md` — all
  reference the `vibing-workspace-*` skills or `.vibing/workspace/` layout and need updating to
  describe the new skill and directory layout.

## Out of scope

- `EnterWorktree`/`ExitWorktree` internal tool names (Agent tool sub-agent isolation) — unrelated
  concept, not touched.
- `WorktreeCreate`/`WorktreeRemove` hook events — only relevant to the `--worktree` CLI-flag
  approach, which this design does not use.
- Automatic migration of any pre-existing `.vibing/workspace/<id>/` workspaces created by the old
  system. Anyone with an active old-style workspace should finish it (equivalent of the old
  `vibing-workspace-done` flow: `git worktree remove` on its `worktree/` subdirectory) before
  relying on the new layout. No migration tooling is built.
