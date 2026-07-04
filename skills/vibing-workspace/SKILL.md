---
name: vibing-workspace
description: Shared reference for the vibing-workspace-create/-enter/-done/-list skills — explains the .vibing/workspace/ directory layout, the meta.yaml schema, and the bundled scripts/vibing-workspace.mjs helper. Read this before running any vibing-workspace-* skill, or when the user asks how workspaces are laid out, wants to inspect/debug a workspace's meta.yaml or plan.md directly, or asks what "workspace" means in a vibing.nvim project.
---

# vibing-workspace: shared reference

A "workspace" is a git-worktree-backed unit of work with trackable lifecycle state, tracked
lifecycle (in-progress vs finished), and one or more chat conversations associated with it. This
replaces ad-hoc `git worktree add` commands with something that remembers what it's for, whether
it's still active, and which chats have touched it.

## Directory layout

```text
<git root>/.vibing/workspace/
├── .counter                          # plain-text global counter (next number to use)
├── active/
│   └── 0001-fix-auth-session-bug/
│       ├── meta.yaml
│       ├── plan.md
│       └── worktree/                 # the actual git worktree
└── done/
    └── 0002-refactor-permission-ui/
        ├── meta.yaml
        └── plan.md                   # worktree/ no longer exists — it was removed on "done"
```

- The `<counter>-<branch>` id is globally unique and monotonically increasing — it's never
  reused, even after a workspace moves from `active/` to `done/`. Refer to a workspace by this
  id (e.g. "0001-fix-auth-session-bug") in conversation; it's the one stable handle.
- Multiple chat conversations can be associated with the same workspace over time (recorded in
  `meta.yaml`'s `chat_files` list) — there's no restriction on how many, and no chat "owns" a
  workspace exclusively.
- A workspace moving to `done/` means its worktree was removed; the `meta.yaml`/`plan.md` record
  stays behind as history. Nothing under `done/` should ever be treated as still checked out.

## meta.yaml schema

Plain-text, not real YAML parsing — just `key: value` lines plus one list field:

```yaml
workspace_id: 0001-fix-auth-session-bug
branch: fix-auth-session-bug
created_at: 2026-07-03T10:00:00.000Z
description: Fix the auth session expiry bug
chat_files:
  - .vibing/chat/2026-07-03-abc.md
  - .vibing/chat/2026-07-04-def.md
```

`chat_files` holds every chat file that has ever worked in this workspace (via the
`vibing-workspace-create` or `vibing-workspace-enter` skills). Paths are relative to the git
root when the current chat file is inside the repo.

## plan.md

A free-form scratchpad with one convention worth knowing: a line matching `- [ ]` (an unchecked
markdown checkbox) is treated as an "incomplete TODO" by the `vibing-workspace-done` skill, which
uses that as a signal to double-check with the user before finishing the workspace. There's no
enforced structure beyond that — read and edit it like any other markdown file as the work
progresses.

## The bundled script

All of the above is managed through `${CLAUDE_PLUGIN_ROOT}/scripts/vibing-workspace.mjs`, a
dependency-free Node script (only needs `node` and `git` on PATH). It has no awareness of Claude,
chat files, or Neovim — it only knows about the directory layout above. Each `vibing-workspace-*`
skill calls it with `Bash` for the mechanical parts (creating the worktree, writing/reading
`meta.yaml`, moving directories) and handles the parts that need judgment (talking to the user,
picking a branch name, deciding whether a warning is worth stopping for) itself.

Every subcommand prints one line of JSON to stdout on success, and exits non-zero with a
plain-text message on stderr on failure — check the exit code, don't just look for JSON.

| Subcommand        | Args                                | Output                                                                                                                                                                                                                  |
| ----------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `create`          | `<branch> <description>`            | `{id, dir, worktree_path, meta_path, plan_path}`                                                                                                                                                                        |
| `list`            | `[active\|done]` (default `active`) | `[{id, branch, description, dir}, ...]`                                                                                                                                                                                 |
| `get`             | `<workspace_id>`                    | `{id, dir, status, meta_path, plan_path, worktree_path?}` (`worktree_path` only present when `status` is `"active"`)                                                                                                    |
| `add-chat-file`   | `<workspace_id> <chat_file_path>`   | `{ok, chat_files}` — no-ops (still succeeds) if the path is already present                                                                                                                                             |
| `remove-worktree` | `<workspace_id>`                    | `{ok}` — runs `git worktree remove` with **no `--force`**; if git refuses because of uncommitted changes, that error reaches you verbatim on stderr so you can tell the user rather than silently discarding their work |
| `move-to-done`    | `<workspace_id>`                    | `{ok, dir}` — only call this after `remove-worktree` succeeds; the worktree must actually be gone first                                                                                                                 |
| `check-done`      | `<workspace_id>`                    | `{plan_incomplete, branch_merged}` — advisory only, for `vibing-workspace-done` to decide whether to ask for confirmation                                                                                               |

Example:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" create fix-auth-session "Fix the auth session expiry bug"
node "$CLAUDE_PLUGIN_ROOT/scripts/vibing-workspace.mjs" list active
```

## Finding the current chat file

`vibing-workspace-create` and `vibing-workspace-enter` both record which chat file is working in
a workspace. If the `vibing-nvim` MCP server is connected, get the current file with
`mcp__vibing-nvim__nvim_get_info` — this is vibing.nvim's own chat buffer, so its path is the
right thing to record. If that tool isn't available (no running Neovim instance), it's fine to
skip recording a chat file — the workspace itself is still created/entered correctly, there's
just nothing to add to `chat_files` yet.
