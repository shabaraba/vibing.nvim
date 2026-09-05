# MCP Tool Surface

Moved out of `.claude/rules/mcp-integration.md`. The tool descriptions shipped by the MCP server
are the authority for arguments; this file is the catalogue plus the behaviour that is not visible
from a description. Setup lives in `claude-plugin/mcp-server/README.md` and
`handbook/lazy-setup-example.lua`.

## How the Server Is Reached

An async RPC server (`lua/vibing/infrastructure/rpc/server.lua`, `vim.loop` TCP, `vim.schedule()`
for safe API calls) is queried by the Node MCP server (`claude-plugin/mcp-server/`) acting as a TCP
client, so both buffer reads and writes are possible without deadlocks. Nothing is installed:
`build.sh` builds the server, and the plugin that carries it is handed to the CLI per session with
`--plugin-dir` (`.claude/rules/architecture.md` → "Plugin Loading, Command Discovery and Startup
Cost").

## User MCP Servers, Slash Commands, Skills, and Subagents

vibing.nvim invokes the `claude` CLI with `--setting-sources user,project,local` (configurable via
`config.agent.setting_sources`), so your existing `~/.claude.json` MCP servers,
`.claude/commands/` project slash commands, `.claude/skills/`, and global settings/subagents are
all available inside vibing.nvim sessions automatically — no extra configuration needed.

## Naming the Tool and the Instance

Two facts decide whether a call reaches the editor the user is looking at, and both have one home
in the distributed plugin: `claude-plugin/skills/nvim-context/SKILL.md` → "Calling the tools". The
other skills and the `nvim-navigator` agent state the rule in a line each and point there, rather
than restating the reasoning — a skill is loaded on its own, so a bare cross-reference would leave
the rule unstated.

**The prefix depends on how the server was registered.** `mcp__vibing-nvim__<tool>` for a plain
user-level entry, `mcp__plugin_vibing-nvim_vibing-nvim__<tool>` when it arrives inside the plugin
— which is the normal case, since vibing.nvim self-hosts that plugin with `--plugin-dir`.

Note what builds that second form: the **plugin** name and the MCP server name, both from
`claude-plugin/.claude-plugin/plugin.json`. The marketplace name never appears in it. This rule
used to be written down as `mcp__plugin_<marketplace>_…`, and
`tests/lua/core/constants/tools_spec.lua` read `marketplace.json` to enforce it — so after the
marketplace was renamed to `vibing`, the list carried an `mcp__plugin_vibing_vibing-nvim__*` entry
the CLI has never once emitted, and a test defended it. Both are gone; the spec reads `plugin.json`
now.

`VIBING_NVIM_MCP_TOOL_PATTERNS` (`core/constants/tools.lua`) still has to be maintained by hand,
because `--allowedTools` accepts nothing but literals. A stale entry there does not break chats:
the hook's suffix match is what actually decides, which is exactly why nothing noticed the dead
one for so long.

**The port has to be named explicitly**, and a subagent does not inherit the chat's. The system
prompt therefore tells the model both to pass its own `rpc_port` and to forward it in any task
prompt it hands a subagent.

## Available Tools

Prefix each with whichever form matches how the server was registered (see above):
`mcp__plugin_vibing-nvim_vibing-nvim__` in the normal self-hosted case,
`mcp__vibing-nvim__` for a plain user-level entry.

- **Buffer**: `nvim_get_buffer` (a chat can be named by `file_path` instead of `bufnr`; `tail_lines`
  and/or `last_section` window a buffer too large to read in full — the RPC response always
  carries the buffer's real total line count, and the MCP tool surfaces it as text whenever the
  window actually truncated the result — #694), `nvim_set_buffer`, `nvim_list_buffers`,
  `nvim_get_info`, `nvim_load_buffer`
- **Cursor/Selection**: `nvim_get_cursor`, `nvim_set_cursor`, `nvim_get_visual_selection`
- **Window/Pane**: `nvim_list_windows`, `nvim_get_window_info`, `nvim_get_window_view`,
  `nvim_list_tabpages`, `nvim_set_window_size`, `nvim_focus_window`, `nvim_win_set_buf`,
  `nvim_win_open_file`
- **Commands**: `nvim_execute`
- **Highlighting**: `nvim_highlight_range`, `nvim_clear_highlight`
- **Annotations**: `nvim_annotate`, `nvim_clear_annotations`
- **Chat**: `nvim_ask_user_question` (renders a choice list in the chat buffer — see
  `handbook/features/chat-ui.md`), `nvim_chat_send_message`, `nvim_chat_create`,
  `nvim_chat_answer_approval`, `nvim_chat_list`, `nvim_chat_conflicts`
- **Instances**: `nvim_list_instances`
- **Quickfix**: `nvim_set_qflist` (pushes a new list; the previous one survives under `:colder`)
- **Debugger**: `nvim_dap_get_state`, `nvim_dap_get_stack_trace`, `nvim_dap_get_variables`,
  `nvim_dap_set_breakpoint`, `nvim_dap_evaluate` (nvim-dap is optional — every one of these
  reports it as missing rather than failing)
- **LSP**: `nvim_lsp_definition`, `nvim_lsp_references`, `nvim_lsp_hover`, `nvim_diagnostics`,
  `nvim_lsp_document_symbols`, `nvim_lsp_type_definition`, `nvim_lsp_call_hierarchy_incoming`,
  `nvim_lsp_call_hierarchy_outgoing`

**Window identification (important):** `nvim_get_window_info({ winnr: 0 })` returns the
**currently active** window, not necessarily the one the user is visually looking at (e.g. the
chat window may not be active when a request is sent). Always call `nvim_list_windows()` first,
match the target by `buffer_name`/`is_current`, and use the returned `winnr` — don't assume
`winnr: 0` is the right window.

## Showing Code

When the user asks to see code, open it rather than describing where it is: `nvim_list_windows` →
pick a window that isn't the chat → `nvim_win_open_file` → `nvim_set_cursor` → `nvim_highlight_range`.
The CLI's system prompt tells the model to do this, so the tools exist to make that instruction
actionable.

**Carry the `winnr` through the whole sequence.** `nvim_win_open_file` restores focus before it
returns, so the window it opened is not the current one. `nvim_set_cursor` without a `winnr` moves
whatever window is active — the chat — and `nvim_highlight_range` wants the `bufnr` the open
returned, not `0`. Both take the target explicitly for this reason; neither errors when pointed at
the wrong one, so the failure is silent.

`nvim_highlight_range` puts an extmark range in the `vibing_highlight` namespace using the
`VibingHighlight` group, which is `default link`ed to `Visual` so `hi VibingHighlight ...` in a
user's config overrides it. It clears itself after `duration_ms` (default 3000; `0` keeps it), and
a second call to the same buffer replaces the first rather than stacking. Out-of-range lines are
clamped to the buffer rather than rejected — search results go stale by a line or two, and pointing
at roughly the right place beats refusing to point.

## Orchestration Tools

`nvim_chat_create({ rpc_port, position?, working_dir?, from_bufnr?, task?, delegated_scope? })`
creates a chat buffer and returns `{ bufnr, file_path, working_dir, position, saved }` as JSON, so
one chat can spawn worker chats, brief each with `nvim_chat_send_message`, and poll them with
`nvim_get_buffer` — which reports a chat buffer's `responding` / `idle` / `waiting_approval` /
`asked_question` / `error` status as a second content block.

Both tools take an optional `from_bufnr`, the caller's own chat buffer number, which records the
relationship in both chat files' frontmatter (`orchestrated` / `orchestrated_by`) instead of
leaving it in prose that a rename or a restart invalidates. Why it stays optional, why the write
happens before the send, and why the list field needs its own scanner:
`handbook/architecture/orchestration.md`.

**`task` (both tools) is one free-text line recording what the caller is asking the target chat to
do** (e.g. `"PR #688 — review fixes, merge, cleanup"`), written into the **caller's own**
`orchestrated` entry for that chat (`<path>|<task>`, `orchestrated_entry.lua`) — never onto the
target's own frontmatter. `nvim_chat_list` projects it back onto the target chat's row, so an
orchestrator driving several workers reconstructs the whole bufnr ↔ PR/issue ↔ assignment mapping
by reading its own frontmatter, with no transcript to re-read after a restart or a context
compaction (#692's postmortem). `task` requires `from_bufnr` — with none, there is no `orchestrated`
entry to write it into, and it is dropped with a warning. On `nvim_chat_send_message`, a later call
with a new `task` replaces the recorded assignment ("the latest instruction wins"); omitting it (the
normal case — a status check, an approval, "go ahead") leaves the existing one untouched.

**`delegated_scope` (`nvim_chat_create` only) is the opposite of `task`: it is written onto the
NEW chat's own `delegated_scope` frontmatter**, a list of tool/command patterns using the same
syntax as `permissions_allow` (e.g. `"Bash(npm:*)"`). It has no effect unless
`agent.orchestration.delegated_approval` is `"scoped"`, in which case it is what
`nvim_chat_answer_approval` checks an `allow_once`/`allow_for_session` answer against for that
chat — see below and `handbook/architecture/orchestration.md` → "Answering a worker's tool
approval".

**The target chat is named by `file_path` or `bufnr`, and the path is the primary form.**
`nvim_chat_send_message` and `nvim_get_buffer` both accept either, open a chat that is closed, and
refuse a call that passes the pair rather than preferring one of them. Why the path rather than
the number, why it opens chat files and refuses everything else, and why `from_bufnr` stays a
bufnr while these do not: `handbook/architecture/orchestration.md` → "Addressing a chat".

`nvim_chat_send_message` also takes `queue_if_busy` (default `false`). A chat that is responding
normally refuses the send; with the flag the message is queued instead and delivered as a new turn
the moment that chat stops, with several queued items coalesced into one turn. The reply says which
happened, and "queued" means no request has started yet — an orchestrator that read it as "sent"
would poll a transcript that has not moved. `task` is queued along with the body and applied at
flush time, same as the immediate path; if several queued messages from the same sender carry a
`task`, the last one wins. Why it is not gated on `chat_notifications`, why the frontmatter link is
written at delivery rather than when the message is queued, and why the queue is capped:
`handbook/architecture/orchestration.md`.

`nvim_chat_answer_approval({ rpc_port, file_path|bufnr, action, from_bufnr })` answers another
chat's pending tool-approval prompt with one of `allow_once` / `deny_once` / `allow_for_session` /
`deny_for_session`. **It is refused unless `agent.orchestration.delegated_approval` is set**, since
what it buys is one agent clearing another agent's permission gate; `from_bufnr` is required here
(unlike on the other two) so the answer is always recorded as somebody's decision. When the setting
is `"scoped"` rather than `true`, an `allow_once`/`allow_for_session` call additionally fails unless
the tool matches the target chat's own `delegated_scope` frontmatter — a denial always succeeds
either way. Why it writes the chosen option line into the worker's buffer instead of applying the
decision directly, and why the watchdog's `waiting_approval` wording changes with the setting:
`handbook/architecture/orchestration.md` → "Answering a worker's tool approval".

`nvim_chat_list({ rpc_port? })` reports every chat buffer open in this Neovim session in one call —
`bufnr`, `file_path`, `chat_status`, `context_size` (the last measured context in tokens, from the
last turn's own `### Tokens` marker; absent until a turn has completed), `updated_at` (frontmatter
timestamp; absent until something has written to frontmatter), `orchestrated_by`, and `task` (that
chat's one-line assignment, projected from its orchestrator's own `orchestrated` entry — present
only when that orchestrator is _also_ open in this session, since the handler never opens a file
just to look up a task). Use it instead of polling several worker chats one at a time with
`nvim_get_buffer`. It is a read like `nvim_list_buffers`, so `rpc_port` stays optional; it only
lists chats attached in this session — a chat file nobody has opened yet does not appear.

`nvim_chat_conflicts({ rpc_port? })` warns (never blocks) about files that 2+ live chats have
modified on their own branch — the mechanical version of what #692's postmortem found only because
a human happened to be looking at both diffs at once (one PR renamed a marker a second PR still
parsed by the old name; that PR's own tests used a fixture, so nothing caught it). It is a read like
`nvim_chat_list`. Only chats with their own `working_dir` (a worktree/branch) are compared — a chat
using the instance's own working directory has nothing of its own to diff — and each one's worktree
is diffed against `main` or `master` (three-dot, against `HEAD`, so no branch name has to be known).
File-level only (v1); `task` is projected the same way `nvim_chat_list` does. Returns
`{ base, conflicts: [{ file, chats: [{ bufnr, file_path, task? }] }], skipped: [{ bufnr, file_path, working_dir, reason }] }`.
A chat whose worktree git could not diff (no merge base with `base`, a removed worktree) is listed
under `skipped` with git's own message rather than dropped, and a repository with neither `main` nor
`master` returns a `warning` — either way an empty `conflicts` never stands in for "not compared".

The workflow is the bundled `vibing-orchestrate` skill. Why `position` defaults to `back`, why the
chat file is written at creation, why the status is a field rather than a text heuristic, and what
is deliberately out of scope: `handbook/architecture/orchestration.md`.

## Inline Review Notes

`nvim_annotate` puts a review point under the line it is about, as extmark `virt_lines` in the
`vibing_annotations` namespace. The file is never written and `modified` never gets set. Severity
picks between `VibingAnnotationInfo` / `Warn` / `Error`, each `default link`ed to the matching
`DiagnosticVirtualText*` group so a user's own `hi` command overrides it. Every annotation line is
prefixed with a `┃` and a space, so a note can't be misread as code.

Annotations are **not persisted** — unloading the buffer takes them with it. That is the intended
lifetime: a review is read once and dismissed. Editing near an annotation moves it the way
extmarks normally move; no attempt is made to re-anchor it.

`nvim_clear_annotations` clears one buffer, or every buffer when `bufnr` is omitted.
`:VibingClearAnnotations` is the same thing from the user's side.

## Background LSP Analysis

All LSP tools work on any loaded buffer, not just the active one. Load a file in the background
with `nvim_load_buffer` (returns `bufnr`), then pass that `bufnr` to LSP tools — this analyzes
code (e.g. call hierarchy) without leaving the current window or switching buffers; the LSP server
keeps analyzing every loaded buffer regardless of display state.
