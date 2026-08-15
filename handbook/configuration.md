# Configuration Reference

Complete reference for every `require("vibing").setup()` option. Defaults shown below match
`lua/vibing/config.lua`.

## Table of Contents

- [Defaults at a Glance](#defaults-at-a-glance)
- [Adapter](#adapter)
- [Grok CLI](#grok-cli)
- [Agent](#agent)
- [Chat](#chat)
- [UI](#ui)
- [Keymaps](#keymaps)
- [Diff](#diff)
- [Permissions](#permissions)
- [Granular Permission Rules](#granular-permission-rules)
- [MCP](#mcp)
- [Node.js Executable](#nodejs-executable)
- [Language](#language)
- [Project System Prompt](#project-system-prompt)
- [Debugger (nvim-dap)](#debugger-nvim-dap)
- [Daily Summary](#daily-summary)

## Defaults at a Glance

```lua
require("vibing").setup({
  adapter = "claude",
  agent = {
    default_mode = "code",
    default_model = "sonnet",
    utility_model = "sonnet",
    setting_sources = { "user", "project", "local" },
    subagent = { enabled = false, show_prefix = false },
    auto_resume_on_limit = { enabled = false, max_retries = 1 },
    scheduled_requests = { enabled = true, max_retries = 3 },
    codex_provider_notice = { enabled = true },
  },
  chat = {
    window = {
      position = "current",
      width = 0.4,
      border = "rounded",
    },
    save_location_type = "project",
    save_dir = vim.fn.stdpath("data") .. "/vibing/chats",
  },
  ui = {
    wrap = "on",
    gradient = {
      enabled = true,
      colors = { "#cc3300", "#fffe00" },
      interval = 100,
    },
    tool_result_display = "compact",
    tool_markers = {
      Task = "▶",
      default = "⏺",
    },
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
    open_diff = "gd",
    open_file = "gf",
    open_url = "gx",
  },
  diff = {
    tool = "auto",
    mote = {
      project = nil,
      context_prefix = "vibing",
    },
  },
  permissions = {
    mode = "acceptEdits",
    allow = { "Read", "Edit", "Write", "Glob", "Grep", "Skill", "StructuredOutput" },
    deny = { "Bash" },
    ask = {},
    rules = {},
  },
  node = {
    executable = "auto",
  },
  mcp = {
    enabled = true,
    rpc_port = 9876,
  },
  language = nil,
  daily_summary = {
    save_dir = nil,
    search_dirs = {},
    file_finder_strategy = "auto",
  },
})
```

## Adapter

```lua
adapter = "claude",  -- Global backend adapter
                     -- "claude":  Claude CLI      (claude -p --output-format stream-json)
                     -- "codex":   Codex CLI       (codex exec --json)
                     -- "copilot": Copilot CLI     (copilot -p --output-format json)
                     -- "grok":    Grok Build CLI  (grok --single=... --output-format streaming-json)
                     -- Overridable per-chat via the "agent" frontmatter field
```

Backends are not feature-equivalent. `AskUserQuestion`'s choice-list UI is Claude-only. Every
backend honours `permissions.mode`, the `ask` list and the Tool Approval UI, but each one reaches
them differently: `copilot` through a generated plugin loaded per run with `--plugin-dir` (written
to `.vibing/copilot-plugin/`; your own `~/.copilot/` is never modified), and `grok` only inside a
git repository — see [Grok CLI](#grok-cli).

## Grok CLI

```lua
grok = {
  executable = "auto",  -- "auto": detect `grok` on PATH (default)
                        -- or an explicit path, e.g. "~/.grok/bin/grok"
}
```

Only read when `adapter = "grok"` (or a chat's `agent: grok` frontmatter). Unlike
`node.executable`, a path that does not exist is **not** reset to `"auto"`: having asked for a
specific binary, silently falling back to whatever `grok` is on PATH would be worse than failing.
vibing.nvim also refuses a `grok` that is not the official xAI Grok Build CLI, since the name is
shared with unrelated tools.

**Permission rules need a git repository.** Grok discovers the PreToolUse hook vibing.nvim installs
(`<cwd>/.grok/hooks/`) only inside a git repo. Outside one the hook is written and never read, so
`permissions.rules`, the `ask` list and the Tool Approval UI silently do nothing — vibing.nvim
warns once per working directory when it detects this.

## Agent

```lua
agent = {
  default_mode = "code",    -- Recorded in each new chat's frontmatter as `mode`
                            -- ("code" | "plan" | "explore"). Currently metadata only —
                            -- it does not change runtime behavior, and is not the same
                            -- thing as permissions.mode = "plan" (which does). Anything
                            -- outside the three values warns and falls back to "code";
                            -- an invalid frontmatter `mode` warns and is dropped.

  default_model = "sonnet", -- Default model for new chats
                            -- "sonnet": Balanced (recommended)
                            -- "opus": Most capable
                            -- "haiku": Fastest
                            -- "fable": Claude Fable

  utility_model = "sonnet", -- Model used for lightweight utility calls
                            -- (AI title generation, chat summaries, daily summaries).
                            -- Takes priority over the chat's model for those calls.
                            -- Set to "haiku" for the cheapest option: it costs less but
                            -- picks the wrong subject noticeably more often.

  setting_sources = { "user", "project", "local" },
                            -- Passed to the Claude CLI's --setting-sources flag.
                            -- Drop "user" to skip loading your global CLAUDE.md on
                            -- every chat, reducing fixed per-session token cost.
                            -- Note: does not affect MCP server loading.

  subagent = {              -- What a subagent (Task/Agent tool) says in the chat
    enabled = false,        -- Opt-in: passes --forward-subagent-text to the CLI so the
                            -- subagent's own text reaches vibing.nvim at all. Without it
                            -- the CLI forwards only the final tool result.
    show_prefix = false,    -- Prefix each forwarded line with [<subagent_type>]
  },

  auto_resume_on_limit = {  -- Resume a chat automatically once a usage limit resets
    enabled = false,        -- Opt-in: this spends tokens with nobody watching
    max_retries = 1,        -- Auto-resumes allowed per limit hit
    prompt = "Continue from where you left off.",
    fallback_delay_sec = 300, -- Used only when no reset timestamp was reported
    grace_sec = 10,         -- Added to the reset time to avoid firing on the boundary
  },

  codex_provider_notice = {
    enabled = true,         -- Warn when a Codex lightweight call leaves your model_provider.
                            -- On by default, unlike the toggles above: it spends no tokens,
                            -- and a warning about a silent change is useless if it is itself
                            -- off by default. Turn it off to stop the `codex doctor --json`
                            -- probe it needs. Codex backend only.
  },
}
```

### Codex Provider Notice

Only applies to the Codex backend. Codex's lightweight calls (chat title generation, `/summarize`,
daily summary) run with `--ignore-user-config`, which is what keeps them out of your MCP servers —
and which also drops `model_provider`. So if your `config.toml` points Codex at a custom or local
provider, those calls go to the default OpenAI endpoint while ordinary chat still uses yours. That
is unexpected billing for some and an unexplained 401 for anyone on a local provider, with nothing
said either way.

With this on, the first lightweight Codex call of a Neovim session runs `codex doctor --json` in
the background to ask Codex which provider is actually configured, and warns once if it is not
`openai`. Nothing waits for the probe, and if Codex cannot answer, nothing is said — a warning that
cannot be trusted is worse than none, because its silence reads as "you are fine".

**Why this one defaults to on** while `subagent` and `auto_resume_on_limit` default to off: those
two spend tokens unattended, so the safe default is silence. This one spends none and exists to
stop a change happening behind your back — off by default, it would fail at exactly the job it has.

Turn it off if you would rather Neovim never spawn the extra process. `codex doctor` has no flag to
run a single check, so the probe also makes one reachability request to the active provider's
endpoint. That is also why an unreachable local provider gets its warning late: the probe waits out
its 10-second timeout first.

### Subagent Output

By default the Claude CLI forwards nothing a subagent says — a `Task`/`Agent` call shows up in
the chat as its header and its final result, with everything in between invisible. Set
`agent.subagent.enabled = true` to pass `--forward-subagent-text`, and the subagent's text is
rendered under the tool header, indented behind a `│` rail:

```text
▶ Agent(code-explorer)
  │ Checked every adapter: only claude_cli.lua reads the flag.
  ⎿ (tool result)
```

The text is buffered per `tool_use_id` and flushed when that tool's result arrives, rather than
streamed as it comes in. Two reasons: the CLI delivers subagent output as complete `assistant`
messages (never as `stream_event` deltas, so there is nothing to stream), and with several
subagents running in parallel, printing on arrival would interleave their voices. Buffering keeps
each subagent's reasoning attached to the call it belongs to.

Only the subagent's assistant text is shown. Its prompt echo, thinking blocks, and its own nested
tool results stay hidden — those belong to the subagent's transcript, not the parent's. Turn on
`show_prefix` when several subagents run at once and you want each line labelled with its type.

Lightweight utility calls (title generation, summaries) never get the flag; they have no tools to
delegate with.

### Auto-Resume on Usage Limit

When a turn is rejected because the plan's usage limit is exhausted, vibing.nvim can park the
chat, wait for the reset, and send a single continuation message so the conversation carries on
by itself.

```lua
require("vibing").setup({
  agent = {
    auto_resume_on_limit = {
      enabled = true,
      max_retries = 1,
      prompt = "Continue from where you left off.",
    },
  },
})
```

**How the limit is detected.** Three independent signals feed one decision
(`lua/vibing/core/utils/rate_limit.lua`):

| Signal                                 | Carries reset time | Role                                     |
| -------------------------------------- | ------------------ | ---------------------------------------- |
| `rate_limit_event` on the CLI's stdout | Yes (`resetsAt`)   | Primary — supplies when to wake up       |
| `StopFailure` hook (`rate_limit`)      | No                 | Confirms the turn actually died          |
| Error text of the failed run           | No                 | Fallback if either payload shape changes |

The reset timestamp is the only thing that makes scheduling possible, and it arrives solely on the
stream event. If it is missing, `fallback_delay_sec` is used instead — bounded in practice by
`max_retries`.

**Persistence.** A five-hour limit resets hours away and a weekly limit days away, so pending
resumes are written to `<project root>/.vibing/pending-resume.json` and re-armed at startup. A
resume still requires Neovim to be running when the timer fires; nothing happens while the editor
is closed, but a chat parked before a restart is picked up after it.

Each chat's entry is stored under the project that owns its **chat file**, not Neovim's current
directory, so a `:cd` or a worktree-backed chat cannot lose a pending resume. Startup recovery and
`:VibingPendingResumes` are still scoped to the project Neovim was opened in — resumes for a
different project are picked up when you open Neovim there.

**Safeguards.** Auto-resume never overwrites an unsent message you left in the chat, stops after
`max_retries` limit hits in a row, and refuses reset timestamps more than 8 days out (a sign the
payload was misread). Several parked chats all resume at once, which is intentional — a reset
hands back a full quota, and concurrent chats are normal usage. Inspect and control pending
resumes with `:VibingPendingResumes` and `:VibingCancelResume`.

### Scheduled Requests

Any chat message can be parked to send later as a **scheduled request** — unlike auto-resume's
fixed continuation prompt, it resends the chat's own message, unedited, at the chosen time. This
is not limited to usage-limit recovery: `:VibingSchedule 18:30` works with no limit ever having
been hit. Two of the three ways a scheduled request gets created, described below, are
specifically about usage limits.

```lua
require("vibing").setup({
  agent = {
    scheduled_requests = {
      enabled = true,    -- Opt-out, not opt-in: a request during an active limit would
                         -- fail anyway, so scheduling it instead is the safer default
      max_retries = 3,   -- Re-schedules allowed if a scheduled send is rejected again
    },
  },
})
```

Scheduled requests come from three places: `:VibingSchedule [when]` (see below), which needs no
recorded limit at all when `when` is given — only the no-argument form reads
`.vibing/limit-state.json`; a `<CR>` sent while that file shows the project's limit is still
active, unless the message is a slash command or a reply to a pending approval prompt (those
always send immediately); and a turn the limit actually rejected, whose message is written back
into a fresh unsent `## User` section instead of being discarded. `:VibingSchedule` always works;
the other two are governed by `scheduled_requests.enabled`.

**Where the body lives.** The scheduled message is never copied into the pending-resume store — it
stays in the chat buffer's unsent `## User` section, visible and editable while parked. Deleting
it before the timer fires empties the section, so the scheduled send finds nothing there and is
dropped. `:VibingSchedule` and the limit-aware `<CR>` interception both save the chat file before
arming the timer, but react differently to a save failure: `:VibingSchedule` simply refuses to
schedule, leaving the message unsent in the buffer, while the `<CR>` interception fails open and
sends the message immediately instead of parking it. Either way, an armed schedule whose body
cannot survive a restart is avoided. The rejected-turn path writes the text back into the buffer
the same way but does not force a save itself — it relies on the buffer being saved for some other
reason before a restart. Because the body is the section rather than a copy of it, a schedule does
not outlive a turn that consumes that section: sending manually with `<CR>` while a request is
parked drops the entry whether the turn succeeds or fails, so the timer can never fire on whatever
text happens to occupy the section later. Only a usage-limit rejection re-parks it.

**`when` formats.** `:VibingSchedule` accepts relative offsets (`90s`, `30m`, `2h`, `1h30m`), a
bare clock time (`18:30` — the next occurrence of that time; already past today rolls to
tomorrow, computed by date rather than by adding 24 hours so it holds across a DST transition), or
an absolute timestamp (`2026-08-14T07:05` or `2026-08-14 07:05`). A zero-length offset (e.g. `0m`)
or an out-of-range clock time is rejected, but an absolute timestamp already in the past is
**not** — it is clamped to fire about 3 seconds later, the same floor auto-resume uses for a
reset time missed while Neovim was closed. With no argument, `:VibingSchedule` uses the project's
recorded usage-limit reset time from `.vibing/limit-state.json`, if any, and errors if there is
none.

**`.vibing/limit-state.json`.** One record per project holding the last observed reset time, so a
chat that never hit the limit itself can still schedule instead of send while another chat's
rejection is still in force. It is written only when the rejection carried a reset timestamp, and
cleared on any successful response, so a limit that lifts early is forgotten as soon as one
request gets through.

**Re-scheduling.** `max_retries` bounds how many times a scheduled request may be rescheduled
after being rejected again. Because the check is applied to the already-incremented retry count,
the default of `3` permits only **2** re-schedules. The next rejection falls through to
`auto_resume_on_limit`'s own handling instead.

That fallback re-checks the same stored `retry_count`, now `2`, against
`auto_resume_on_limit.max_retries`. With both settings at their defaults that budget is already
spent, so the request is simply dropped rather than falling back to the fixed continuation prompt.
The prompt only fires if `auto_resume_on_limit.max_retries` has been raised above what the
scheduled retries already consumed.

**`:VibingCancelResume`** cancels either an auto-resume or a scheduled request, and also clears the
project's recorded usage limit — so "send now" (cancel, then `<CR>`) actually sends instead of
being re-parked by the stale record. If the limit is genuinely still in force, the next rejected
response re-records it.

## Chat

```lua
chat = {
  window = {
    position = "current",  -- "current": open in current window
                           -- "right" / "left": vertical split
                           -- "top" / "bottom": horizontal split
                           -- "back": background buffer only (no window)
                           -- "float": floating window

    width = 0.4,           -- Applied to right/left splits and floating windows.
                           -- Below 1 it is a screen-width ratio; 1 or above is an
                           -- absolute column count (e.g. width = 80). Note the
                           -- boundary: width = 1 means one column, not 100%.

    -- height is not in the defaults on purpose: the fallback differs per position
    -- (0.4 for top/bottom splits, 0.8 for floats), and a value here would apply to
    -- both. Set it to override either.
    --   height = 0.5,     -- Same rule as width: ratio below 1, absolute rows at 1
                           -- or above. Applies to top/bottom splits and floats.

    border = "rounded",    -- Border for position = "float" only (any nvim_open_win
                           -- border spec). Split windows have no border.
  },

  save_location_type = "project",  -- Chat file save location
                                   -- "project": .vibing/chat/ in project root
                                   -- "user": stdpath("data") .. "/vibing/chats"
                                   -- "custom": use save_dir

  save_dir = vim.fn.stdpath("data") .. "/vibing/chats",  -- Used when save_location_type = "custom"
}
```

Chat files are created as Markdown (`chat-<timestamp>-....md`) inside the save location.

## UI

```lua
ui = {
  wrap = "on",  -- "nvim": respect Neovim defaults (don't touch wrap settings)
                -- "on": enable wrap + linebreak (recommended for chat readability)
                -- "off": disable line wrapping

  tool_result_display = "compact",  -- "none": don't show tool results
                                    -- "compact": first 100 characters only (default)
                                    -- "full": complete tool output

  gradient = {
    enabled = true,   -- Animate line numbers while the AI is responding
    colors = { "#cc3300", "#fffe00" },  -- Exactly 2 hex colors: { start, end }
    interval = 100,   -- Animation update interval (ms)
  },

  tool_markers = {
    Task = "▶",      -- Marker for the Task tool
    default = "⏺",   -- Default marker for all other tools

    -- Per-tool string markers (optional):
    -- Read = "📄",
    -- Edit = "✏️",
    -- Bash = "💻",
  },
}
```

Every `tool_markers` entry is a plain string. Markers are resolved from the tool name alone, so
they cannot vary with a tool's arguments (there is no way to give `Bash` one marker for `npm` and
another for `git`). The legacy `Bash = { default = "💻" }` table form is still accepted — it is
flattened to the `default` string with a warning — but should be replaced with `Bash = "💻"`.

## Keymaps

Chat-buffer key bindings (all six are configurable; `q` to close the window is fixed):

```lua
keymaps = {
  send = "<CR>",         -- Send message
  cancel = "<C-c>",      -- Cancel current request
  add_context = "<C-a>", -- Add file to context
  open_diff = "gd",      -- Open diff viewer on file paths
  open_file = "gf",      -- Open file on file paths
  open_url = "gx",       -- Open URL on current line in browser
}
```

## Diff

How diffs work by default (regardless of `diff.tool`): when a write tool (Write / Edit /
MultiEdit / NotebookEdit) is approved, the target file's pre-edit content is backed up at
PreToolUse-hook time; when the response completes, a git-style patch is generated in-process
with `vim.diff()` (no external commands, no tree scanning) and stored under `.vibing/patches/`.
`gd` on a changed file shows that patch first.

`diff.tool` controls two things: whether mote snapshots are also taken, and what `gd` falls
back to when no patch file exists for the file (e.g. changes made via Bash, or reopening an
old chat):

```lua
diff = {
  tool = "auto",  -- "auto" / "git": no mote; fallback viewer is `git diff`
                  --                 (these two currently behave the same)
                  -- "mote": take mote snapshots and fall back to mote diff
                  --         (catches Bash-driven file changes too)
  mote = {
    project = nil,              -- Project name (nil = auto-detect from git repo name)
    context_prefix = "vibing",  -- Prefix for mote context names
  },
}
```

mote is **opt-in**: it runs only when `tool = "mote"` is set explicitly, or when a chat has
`mote_dirs` in its frontmatter (added via `:VibingMoteDir` — those directories use mote
regardless of `tool`). See [MIGRATION_MOTE.md](./MIGRATION_MOTE.md) for mote setup details.

## Permissions

```lua
permissions = {
  mode = "acceptEdits",  -- Permission mode
                         -- "default": ask for confirmation each time
                         -- "acceptEdits": auto-approve Edit/Write (recommended)
                         -- "plan": forwarded to the CLI as --permission-mode plan
                         --         (read-only planning enforced by the CLI itself)
                         -- "auto": approve everything not matched by the deny
                         --         list / deny rules
                         -- "dontAsk": deny instead of prompting
                         -- "bypassPermissions": auto-approve all (use with caution)

  allow = {              -- Tools to allow (empty = allow all except denied)
    "Read", "Edit", "Write", "Glob", "Grep", "Skill", "StructuredOutput",
                         -- Add "Task" (or "Agent" — same launcher, newer CLI name) to let a chat
                         -- spawn subagents. Left out by default: a subagent runs a whole nested
                         -- session with these same permissions, unattended.
  },

  deny = { "Bash" },     -- Tools to deny (takes precedence over allow)

  ask = {},              -- Tools requiring confirmation before each use

  rules = {},            -- Granular rules — see next section
}
```

Valid tool names: `Read`, `Edit`, `Write`, `Bash`, `Glob`, `Grep`, `WebSearch`, `WebFetch`,
`Skill`, `StructuredOutput`. Bash command patterns (`Bash(git:*)`) and MCP tool names
(`mcp__server__tool`) are also accepted in the lists.

Two built-in behaviors to be aware of:

- `Read`, `Skill`, and `StructuredOutput` are **always allowed** regardless of the allow list
  (they can still be blocked via `deny`).
- `Skill` is automatically appended to `allow` unless you put it in `deny` or `ask`.

## Granular Permission Rules

Fine-grained control based on tool inputs:

```lua
permissions = {
  mode = "default",
  rules = {
    -- Allow reading specific paths
    { tools = { "Read" }, paths = { "src/**", "tests/**" }, action = "allow" },

    -- Deny writes to sensitive files, with a custom message
    {
      tools = { "Write", "Edit" },
      paths = { ".env", "*.secret" },
      action = "deny",
      message = "Cannot modify sensitive files",
    },

    -- Allow specific Bash commands (exact base-command match)
    { tools = { "Bash" }, commands = { "npm", "yarn" }, action = "allow" },

    -- Deny dangerous Bash command patterns (Lua patterns — escape "-" as "%-")
    { tools = { "Bash" }, patterns = { "^rm %-rf", "^sudo" }, action = "deny" },

    -- Restrict web fetches to specific domains
    { tools = { "WebFetch" }, domains = { "github.com", "*.npmjs.com" }, action = "allow" },
  },
}
```

Field reference:

| Field      | Applies to                                              | Matching                                                                                                         |
| ---------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `tools`    | any                                                     | Exact tool-name match                                                                                            |
| `paths`    | tools whose input has a file path (Read/Write/Edit/...) | Glob: `*` (single dir), `**` (recursive); paths are normalized to absolute, symlink-resolved form first          |
| `commands` | `Bash` only                                             | Exact match against the base command (first word)                                                                |
| `patterns` | `Bash` only                                             | **Lua patterns**, not regex — escape `-` as `%-` (e.g. `"^rm %-rf"`). Patterns longer than 500 chars are ignored |
| `domains`  | `WebFetch` only                                         | Domain match with `*.` wildcard support                                                                          |
| `action`   | —                                                       | `"allow"` or `"deny"`                                                                                            |
| `message`  | —                                                       | Shown when a `deny` rule blocks a call                                                                           |

Evaluation notes:

- `deny` rules run **before** the permission mode, the tool-level lists, and any session-level
  grant, so a denied call stays denied under `mode = "auto"`, for always-allowed tools, and after
  an "allow for this session" approval. `mode = "bypassPermissions"` is the one deliberate way
  past them.
- `allow` rules are evaluated **after** the tool-level `allow`/`ask` lists.
- A rule whose condition doesn't apply to the tool's input (e.g. `paths` on a `Bash` call)
  is skipped.

## Default Deny Rules

vibing.nvim ships deny rules for a small set of destructive Bash commands, enabled by default:

```lua
permissions = {
  default_deny_rules = true,  -- set to false to ship nothing and rely on your own rules
}
```

| Blocked                              | Examples                                                      |
| ------------------------------------ | ------------------------------------------------------------- |
| Recursive deletion of `/` or `$HOME` | `rm -rf /`, `rm -rf /*`, `rm -rf ~`, `rm -rf $HOME`           |
| Privilege escalation                 | `sudo ...`, `doas ...`                                        |
| Raw device writes                    | `dd ... of=/dev/sda`, `mkfs.ext4 /dev/sda1`                   |
| World-writable trees                 | `chmod -R 777 .`, `chmod 777 -R .`                            |
| Force-pushing main/master            | `git push --force origin main` (`--force-with-lease` is fine) |

They match after shell separators **and after newlines**, so both `cd /tmp && sudo rm -rf /` and a
`sudo` on the second line of a multi-line script are caught — the Bash tool hands a whole script
over as one command. The full list lives in
`lua/vibing/core/constants/destructive_commands.lua`.

Known gaps — these are a safety net, not a sandbox:

- Split short flags (`rm -r -f /`) and obfuscation (`$(echo rm) -rf /`) are not matched. Combined
  short flags (`-rf`), GNU longform (`--recursive`) and quoted targets (`rm -rf "$HOME"`) are.
- Flag order does not matter. GNU `getopt_long` permutes options, so `rm / -rf` and
  `chmod 777 -R .` run exactly as their flag-first spellings do and are matched the same way.
- `dd` is judged by its write target only: `dd ... of=/dev/...` is blocked, an ordinary
  file-to-file copy such as `dd if=backup.img of=backup2.img` is not.
- Matching never reaches across a newline to assemble a hit from two different lines, but it
  cannot tell a real command from the same text quoted inside an `echo` on its own line.
- Matching is case-sensitive; every command covered here is a lowercase Unix command name.
- A bare `git push --force` is allowed, because a pattern cannot know which branch it lands on.
  Naming the branch is caught in either flag order (`--force origin main` and `origin main
--force`), and a branch that merely starts with main/master (`main-v2`) is not.
- `permissions.deny`/`allow` cannot switch off an individual bundled rule; use
  `default_deny_rules = false` and re-add the ones you want to `rules`.

The point is that the boundary is drawn in the environment rather than in an approval prompt:
prompts are approved reflexively most of the time, so they are a last line of defence, not the
primary one.

## MCP

Enables the RPC server that the bundled `vibing-nvim` MCP server connects to (see the README's
Installation section for how the MCP server itself is installed via the Claude Code plugin):

```lua
mcp = {
  enabled = true,   -- Start the Neovim-side RPC server
  rpc_port = 9876,  -- RPC server port
}
```

## Node.js Executable

```lua
node = {
  executable = "auto",  -- "auto": detect from PATH (default)
                        -- or an explicit path, e.g. "/usr/local/bin/node"
                        -- (bun and other Node-compatible runtimes work too)
}
```

During plugin installation (`build.sh`), the `VIBING_NODE_EXECUTABLE` environment variable
controls which binary is used for the build:

```bash
VIBING_NODE_EXECUTABLE=/usr/local/bin/bun ./build.sh
```

Or in your lazy.nvim spec:

```lua
{
  "shabaraba/vibing.nvim",
  build = "VIBING_NODE_EXECUTABLE=/usr/local/bin/bun ./build.sh",
  config = function()
    require("vibing").setup({
      node = { executable = "/usr/local/bin/bun" },
    })
  end,
}
```

## Language

Configure AI response language:

```lua
-- Simple: all responses in one language
language = "ja"  -- "ja", "en", "zh", "ko", "fr", "de", "es", ...

-- Advanced: per-context language
language = {
  default = "ja",  -- Default language
  chat = "ja",     -- Chat responses (falls back to default)
}
```

## Project System Prompt

`.vibing/system-prompt.md` holds instructions that apply to every chat in this project. The file
is created empty the first time a chat is saved into the project, and its contents are appended to
the system prompt of every request.

```markdown
Prefer `pnpm` over `npm` in this repository.
Generated files live under `src/generated/` — never edit them by hand.
```

Notes:

- Edits take effect from the **next message**; there is no reload command.
- The system prompt is part of the prompt cache's forward prefix, so editing the file invalidates
  the cached prefix once. Leaving it untouched keeps the cache intact across turns.
- An empty or whitespace-only file is treated as "not set" and adds nothing to the request.
- Content over 8 KiB is truncated (with a warning) to keep it from dominating every request.
- Utility calls (title generation, summarize, daily summary) do not receive it.
- The file is read from the project root Neovim was started in, and is not committed
  (`.vibing/` is git-ignored) — it is per-checkout, not shared with collaborators.
- A chat with a `working_dir` (a worktree under `.vibing/worktrees/<branch>/`) uses that
  directory's `.vibing/system-prompt.md` when it exists and has content, and otherwise falls back
  to the project root's file — so a worktree can override the project prompt without having to
  copy it.

## Debugger (nvim-dap)

```lua
dap = {
  enabled = false,             -- Subscribe to nvim-dap's stopped event.
                               -- Everything below is inert until this is true; the MCP
                               -- nvim_dap_* tools work regardless, on demand.
  auto_analyze_on_error = true,      -- Analyze automatically when the program stops on an
                                     -- exception — something is already wrong there
  auto_analyze_on_breakpoint = false, -- ...but not on an ordinary breakpoint, which you placed
                                     -- on purpose and may hit in a loop
}
```

`:VibingDebugAnalyze` and `:VibingDebugHelp` work without `enabled`; the flag only controls whether
stopping fires a request by itself. Requires [nvim-dap](https://github.com/mfussenegger/nvim-dap);
without it, both commands and all `nvim_dap_*` tools say so rather than failing.

What gets sent is only the request — never a dump of the stack and variables. The agent pulls
whatever depth it needs through the tools, so a large object graph never lands in the prompt
uninvited. See `.claude/rules/features.md` → "Debugger Analysis".

## Daily Summary

Settings for `:VibingDailySummary` / `:VibingDailySummaryAll`:

```lua
daily_summary = {
  save_dir = nil,  -- nil: auto-detect from the chat save directory
                   --      (".../chat/" becomes ".../daily/", otherwise "daily/" is appended)
                   -- string: custom path (relative, absolute, or vim.fn.expand("~/..."))

  search_dirs = {},  -- Directories for :VibingDailySummaryAll
                     -- {} (default): search the standard locations (project .vibing/chat,
                     --     user data dir, custom save_dir)
                     -- { "~/workspaces" }: search ONLY the listed directories.
                     --     Each entry is scanned for `.vibing` directories (max depth 5,
                     --     skipping node_modules/.git/build/dist) and chat files are
                     --     collected from their chat/ subdirectories.

  file_finder_strategy = "auto",  -- File search backend
                                  -- "auto": pick the best available tool
                                  -- "fd" | "find" | "locate" | "ripgrep": force one
}
```

**Usage:**

```vim
:VibingDailySummary [YYYY-MM-DD]     " Current project's chats only (default: today)
:VibingDailySummaryAll [YYYY-MM-DD]  " search_dirs if configured, otherwise default locations
```

Summary files are saved as `YYYY-MM-DD.md` with YAML frontmatter (date, source files, total
messages).
