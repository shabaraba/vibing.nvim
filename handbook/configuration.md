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
    default_effort = nil,
    utility_effort = "low",
    setting_sources = { "user", "project", "local" },
    mcp = { user_servers = true },
    git_instructions = false,
    subagent = { enabled = false, show_prefix = false },
    auto_resume_on_limit = { enabled = false, max_retries = 1 },
    scheduled_requests = { enabled = true, max_retries = 3 },
    codex_provider_notice = { enabled = true },
    token_usage = {
      enabled = true,
      warn_context = 150000,
      cache_ttl_sec = 3300,
      auto_compact = { enabled = false, at = 200000 },
    },
    plugins = { self = true, project_dir = ".vibing/plugins", extra = {} },
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
  },
  permissions = {
    mode = "acceptEdits",
    allow = { "Read", "Edit", "Write", "Glob", "Grep", "Skill", "StructuredOutput" },
    deny = { "Bash" },
    ask = {},
    rules = {},
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

Only read when `adapter = "grok"` (or a chat's `agent: grok` frontmatter). A path that does not
exist is **not** reset to `"auto"`: having asked for a specific binary, silently falling back to
whatever `grok` is on PATH would be worse than failing.
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

  default_model = "sonnet", -- Default backend model id for new chats
                            -- Claude examples: "sonnet", "opus", "haiku", "fable"
                            -- Codex example: "gpt-5.6-terra"

  utility_model = "sonnet", -- Model used for lightweight utility calls
                            -- (AI title generation, chat summaries, daily summaries).
                            -- Takes priority over the chat's model for those calls.
                            -- Set to "haiku" for the cheapest option: it costs less but
                            -- picks the wrong subject noticeably more often.

  default_effort = nil,     -- Reasoning effort recorded in new chat frontmatter.
                            -- "low" | "medium" | "high" | "xhigh" | "max".
                            -- Claude receives --effort, Codex receives a
                            -- model_reasoning_effort config override, and Grok
                            -- receives --effort. nil leaves each CLI's default intact.
                            -- The selected model may support only a subset of the levels.

  utility_effort = "low",  -- Effort for lightweight utility calls. Takes priority
                            -- over the chat's effort, like utility_model above.

  setting_sources = { "user", "project", "local" },
                            -- Passed to the Claude CLI's --setting-sources flag.
                            -- Drop "user" to skip loading your global CLAUDE.md on
                            -- every chat, reducing fixed per-session token cost.
                            -- Note: does not affect MCP server loading — that is
                            -- agent.mcp.user_servers, right below.

  mcp = {                   -- Which MCP servers an ordinary turn loads. Claude backend only.
                            -- Not to be confused with the top-level `mcp` block, which
                            -- configures vibing.nvim's own RPC server.
    user_servers = true,    -- Keeps today's behaviour: every server in ~/.claude.json is
                            -- loaded, because --setting-sources also brings in your own
                            -- commands, skills and subagents. Set false to pass
                            -- --strict-mcp-config and re-register only the MCP servers the
                            -- plugins vibing.nvim loads declare — see "Excluding User MCP
                            -- Servers".
  },

  git_instructions = false, -- Claude backend only. The CLI's own git status block (branch,
                            -- `git status --short`, recent commits) plus its built-in commit/PR
                            -- workflow instructions. Off because the CLI computes that block
                            -- once per process and vibing.nvim starts one per turn — see
                            -- "Token Usage" below. Set true to get the old behaviour back —
                            -- which also overrides includeGitInstructions in your settings.json,
                            -- since both values are written through the CLI's env var.
                            -- An already-set CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS wins either way.

  env = {},                 -- Claude backend only. Extra environment variables for the CLI child
                            -- process, so the cost knobs Claude Code exposes only through the
                            -- environment apply to vibing.nvim's calls and not to the `claude` in
                            -- your terminal. Values are stringified. See "Claude CLI Environment
                            -- Variables" below for what is worth setting; a chat's `env:`
                            -- frontmatter overrides this per chat, CLAUDECODE and VIBING_* are
                            -- refused, and lightweight utility calls get none of it.

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

  chat_notifications = {    -- Tell a chat when a chat it messaged finishes responding
    enabled = false,        -- Opt-in: the notification arrives as a new turn, so it spends
                            -- tokens with nobody watching. This governs the WATCHDOG only —
                            -- the volunteered "that chat stopped, go and read it" for a chat
                            -- that stopped normally. A chat that stopped on a question, a
                            -- tool-approval prompt, or an error is reported to whoever
                            -- messaged it whatever this is set to: those three kill the turn,
                            -- so the chat cannot report for itself, and it will not run again
                            -- until someone acts on it
    max_round_trips = 8,    -- Notifications delivered between one pair of chats without a
                            -- manual <CR>. A→B→A→B is legitimate (B asks, A answers), so the
                            -- chain is bounded by count rather than refused as a cycle. The
                            -- pair is undirected, so a worker's question and the answer to it
                            -- spend two of these, while an orchestrator waking on a worker's
                            -- completion spends one
    max_wakes = 50,         -- Whole-tree budget: notifications delivered without a manual <CR>,
                            -- counted across the editor. A last resort for shapes that spread
                            -- over many pairs and so stay under the limit above — an unbounded
                            -- fan reaches it, and so does a long enough cycle (a 3-chat one is
                            -- caught by max_round_trips first, at these defaults)
  },

  orchestration = {         -- How the chat network is allowed to run
    max_concurrent = 0,     -- How many chats may be responding at once. 0 is no limit, which
                            -- is the default: switching it on changes the order in which an
                            -- existing orchestration's messages arrive. Only machine-started
                            -- sends are held (nvim_chat_send_message and queued deliveries) —
                            -- your own <CR> never waits. The total also counts subagents
                            -- (Task/Agent tool calls) each responding chat has launched and not
                            -- yet gotten a result for — five chats within this limit can still be
                            -- twenty processes deep if each fans out four subagents (#701). The
                            -- count does include chats you are
                            -- driving by hand, so one long manual turn occupies a slot. A send
                            -- that hits the limit is refused unless it passed queue_if_busy,
                            -- in which case it is queued and delivered the moment one of the
                            -- running chats finishes
    max_concurrent_subagents = 0,
                            -- How many subagents (Task/Agent tool calls) may be in flight at
                            -- once, summed across every chat. 0 is no limit, which is the
                            -- default. Unlike max_concurrent, which folds subagents into the
                            -- same total as responding chats, this throttles subagent fan-out on
                            -- its own — useful when chats themselves are not the bottleneck but
                            -- an unbounded number of subagents is
    delegated_approval = false,
                            -- Let one chat answer another chat's tool-approval prompt. A worker
                            -- that hits a tool in its `ask` list has its turn killed and the
                            -- prompt drawn into its own buffer: it cannot continue and cannot
                            -- report that it is stuck, so with this off you have to find each
                            -- blocked worker and answer it yourself.
                            --
                            -- true: the orchestrator answers instead (nvim_chat_answer_approval),
                            -- choosing among the same four options you would, for any tool.
                            --
                            -- "scoped": the same call, but an allow_once/allow_for_session answer
                            -- only succeeds if the tool matches a pattern in the WORKER'S OWN
                            -- `delegated_scope` frontmatter (declared via nvim_chat_create's
                            -- delegated_scope argument, same syntax as permissions_allow, e.g.
                            -- "Bash(npm:*)"). A denial always succeeds regardless of scope, since
                            -- denying grants nothing.
                            --
                            -- Off by default either way, because this is an agent clearing
                            -- another agent's permission gate — a change to the permission model,
                            -- not a convenience. The answer is written into the worker's
                            -- transcript as `## Request ... from <that chat>`, so who granted
                            -- what is readable afterwards
  },

  codex_provider_notice = {
    enabled = true,         -- Warn when a Codex lightweight call leaves your model_provider.
                            -- On by default, unlike the toggles above: it spends no tokens,
                            -- and a warning about a silent change is useless if it is itself
                            -- off by default. Turn it off to stop the `codex doctor --json`
                            -- probe it needs. Codex backend only.
  },

  token_usage = {           -- Per-turn token breakdown in the chat. Claude also warns when the
                            -- conversation has grown; Codex's stream has no context-fill figure.
                            -- On by default for the same reason as codex_provider_notice: it
                            -- spends no tokens, and hidden usage is exactly what it prevents.
    enabled = true,
    warn_context = 150000,  -- Claude: at or above this, every turn's section gains a warning
                            -- under the metrics. Written into the buffer rather than notified,
                            -- and repeated each turn, so it is present when the cost is read.
                            -- 0 keeps the metrics and never warns. Not applied to Codex.

    auto_compact = {        -- Compact a grown chat using the active backend's own mechanism.
                            -- Claude inserts `/compact`; Codex configures its native threshold.
                            -- Off by default. See "Automatic compaction" below.
      enabled = false,
      at = 200000,          -- Context size at which to compact. On Claude, this is checked
                            -- before the next manual send. On Codex it is passed as
                            -- model_auto_compact_token_limit. 0 disables the override.
      focus = nil,          -- Appended as `/compact <focus>` — what the summary should keep,
                            -- e.g. "the open tasks and the files changed so far". No default,
                            -- because a wrong one would quietly shape every summary.
                            -- Claude only; Codex uses only enabled and at.
    },
  },

  plugins = {               -- Claude Code plugins loaded for the session with --plugin-dir
                            -- (claude) or as -c overrides (codex). See "Plugin Directories".
    self = true,            -- vibing.nvim's own claude-plugin/ — the nvim_* MCP tools and
                            -- every bundled skill. Turning this off removes all of them;
                            -- it is a debugging escape hatch, not a normal setting.
    project_dir = ".vibing/plugins",
                            -- Directories under this (relative to the project) are each
                            -- loaded as a plugin. false disables the whole convention.
    extra = {},             -- Additional paths: absolute, ~-relative, or relative to the
                            -- request's working directory.
  },
}
```

### Plugin Directories

vibing.nvim does not install anything into Claude Code's global state. Its own `claude-plugin/`
— the `vibing-nvim` MCP server, the bundled skills, the `nvim-navigator` subagent — is handed to
the CLI per request with `--plugin-dir`, which loads a plugin for that session only. So the MCP
server is always the one belonging to the checkout that spawned it, worktrees included, and there
is no install, update or uninstall step to keep in sync.

The same flag carries your own project plugins. A directory under `.vibing/plugins/` that
contains a `.claude-plugin/plugin.json` is loaded for chats in that project:

```text
.vibing/plugins/
├── _template/                      # inactive skeleton, written on the first chat
└── my-tooling/
    ├── .claude-plugin/plugin.json  # { "name": "my-tooling", ... }
    ├── skills/
    │   └── deploy/SKILL.md         # offered as `my-tooling:deploy` in the `/` picker
    └── agents/
        └── reviewer.md             # offered as a subagent
```

`:VibingCreatePlugin my-tooling` writes that skeleton and opens its example skill. Without an
argument it prompts for the name. Names are lowercase letters, digits, `-` and `_`, because a
skill is namespaced as `<plugin>:<skill>` and the directory is passed to a shell-invoked CLI.

The directory is created on the first chat in a project, holding `_template/` alone. That is a
complete plugin, kept inactive because **a directory whose name starts with `_` is skipped**: an
example skill that loaded by default would spend prompt tokens in every request of every project
and sit in the `/` picker. Copy it to a plain name, or use the command, to turn it on.

The same rule parks a plugin you are not using: rename `my-tooling` to `_my-tooling` and it stops
loading without being deleted. Parked directories are skipped silently — unlike a broken manifest,
they are inactive on purpose.

Claude Code also honours `commands/` and `hooks/` inside a plugin. They work; they just do not
appear in vibing.nvim's `/` completion, which lists skills and subagents.

Run `:VibingReloadCommands` after adding, removing or fixing one — resolution is cached per
working directory, and that command is what drops the cache. `:VibingCreatePlugin` drops it for
you.

**Order matters, and it is `self` → `project_dir` → `extra`.** When two directories declare the
same plugin name the CLI keeps the first and ignores the rest, so a project plugin cannot shadow
vibing.nvim's own by taking its name.

**Worktrees read both locations.** `.vibing/` is git-ignored, so a worktree checkout usually has
no `.vibing/plugins` of its own. A chat whose `working_dir` is a worktree gets the worktree's
plugins _and_ the root's, with the worktree winning where both declare the same plugin name —
so a worktree can add or override a plugin without losing the rest.

**A broken plugin is reported.** `--plugin-dir` ignores a directory with no manifest, an
unparseable manifest or a nonexistent path in complete silence, which makes "I put it there and
nothing happened" impossible to diagnose. vibing.nvim checks first and warns once per working
directory instead.

**Lightweight calls get none of this.** Title generation, `/summarize` and the daily summary run
with no tools and no project config; loading plugins there would only spend prompt tokens on
skill descriptions nothing can invoke.

**Codex gets the same plugins, minus subagents.** The Codex CLI has no `--plugin-dir`; its plugins
are installed globally with `codex plugin add`, which is what this convention exists to avoid. So
for a codex chat vibing.nvim reads each resolved plugin itself and passes the two halves that
codex can take per run: every `mcpServers` entry becomes a `-c mcp_servers.<name>.*` override
(pre-approved at codex's own gate, because headless `codex exec` cancels an MCP call it would
have prompted for; vibing.nvim's permission hook still decides), and every `skills/<name>/SKILL.md`
is listed for the model in `-c developer_instructions` with its path, in the same shape codex
uses for its own skills. Codex normalizes a hyphenated server label to underscores when it builds
tool names, so the bundled server's tools reach the model — and its own PreToolUse hook — as
`mcp__vibing_nvim__<tool>`; `codex_tool_vocabulary` restores the canonical `mcp__vibing-nvim__<tool>`
spelling before the shared permission check runs. Codex's own `.agents/skills` discovery is
unaffected. `agents/` has no codex equivalent and is not passed.
A server whose name contains `.` or a space cannot be expressed on the codex command line and is
skipped with a warning. One more cost: a `developer_instructions` you set in codex's own
`config.toml` is replaced for vibing.nvim chats, since codex offers no additive form.

> **Trust.** A plugin may declare `mcpServers`, so `.vibing/plugins/` in a repository you cloned
> can start a process on your machine on the first message you send. This is a stronger thing
> than the instructions an unreviewed `.claude/skills/` can inject, and it is the reason Claude
> Code gates a project's own `.mcp.json` behind approval. vibing.nvim reads the directory by
> default anyway, on convenience grounds — set `project_dir = false` for repositories you do not
> trust.

### Excluding User MCP Servers

`agent.mcp.user_servers = false` keeps an ordinary turn down to the MCP servers vibing.nvim
brought itself:

```lua
agent = { mcp = { user_servers = false } },
```

The reason it is not the default, and the reason it is one switch rather than a per-server list,
is `--setting-sources user,project,local`: that flag is what makes your own `.claude/commands/`,
skills and subagents work inside a chat, and every MCP server in `~/.claude.json` rides along with
them. The CLI's only counter-switch is `--strict-mcp-config`, which is **all-or-nothing** — it
drops the servers a `--plugin-dir` plugin declares too. So the option is a pair: the strict flag
plus an explicit `--mcp-config` re-registering what each loaded plugin declares.

What that costs and saves, measured against claude 2.1.231 in an environment with 23 registered
servers (9 local stdio, 14 `claude.ai` connectors), one identical one-line prompt per run:

| run                                             | tools | of which MCP | prompt tokens |
| ----------------------------------------------- | ----: | -----------: | ------------: |
| default                                         |   204 |          171 |        46,277 |
| `--strict-mcp-config` alone (drops vibing-nvim) |    30 |            0 |        42,323 |
| `user_servers = false`                          |    72 |           42 |        43,293 |

**~3k prompt tokens a turn, about 6%.** Small, because Tool Search (on by default from Claude
4.5) defers the schemas: what survives in the prompt is a bare name per tool, roughly 23 tokens.
The startup cost does not move either — the servers connect in the background, `duration_ms` was
~2s in all three runs.

With Tool Search off (`ENABLE_TOOL_SEARCH=0`) the same two runs are 241,510 and 73,344 prompt
tokens: **168k tokens, 70%.** That is the case this option is really for.

Three consequences worth knowing before switching it on:

- **Project `.mcp.json` and local-scope servers go too**, not just the user-scope ones —
  `--strict-mcp-config` does not distinguish. An external server you want to keep can be declared
  in `.vibing/plugins/<name>/.claude-plugin/plugin.json` under `mcpServers`, which is re-registered
  along with vibing.nvim's own.
- **The tool prefix changes** from `mcp__plugin_vibing-nvim_vibing-nvim__<tool>` to the plain
  `mcp__vibing-nvim__<tool>`. Both are already permitted and both are named in the system prompt,
  so nothing has to be reconfigured — but a hand-written permission rule naming only the plugin
  form stops matching.
- **Claude only.** Codex has no per-run switch narrower than `--ignore-user-config`, which also
  drops `model_provider`; copilot and grok have none at all for ordinary turns. Lightweight calls
  on every backend already load no MCP servers (`handbook/architecture/lightweight-calls.md`).

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

### Token Usage

When `token_usage.enabled` is true, every Claude and Codex turn ends with a section naming what
it cost, alongside
`### Modified Files`. Claude exposes the request-level split:

```markdown
### Tokens

context 205k · 12 requests · read 2.4M · new 12k
```

The reason it reports those four numbers rather than a total is that the cost of a turn is
**requests × context size**, and neither factor is visible otherwise. Each tool call is another
API request, and every request re-reads the whole conversation — so a turn with twelve tool calls
in a 205k chat reads 2.4M tokens whether the reply was one line or fifty. `context` is the largest
prompt the turn sent, which is the conversation's current size; a subagent's requests are counted
separately and deliberately left out of it, because a subagent runs in its own much smaller
context (measured at 83k against a main chain's 208k) and so says nothing about how big this chat
has grown.

Codex exposes a different aggregate, so its section uses the counters the CLI can establish:

```markdown
### Tokens

input 80k (cached 75k) · output 3k (reasoning 2k)
```

On a resumed Codex thread, `turn.completed.usage` is cumulative for the session. The heading keeps
those exact cumulative counters in an HTML comment, and vibing.nvim subtracts the preceding Codex
footer before rendering the visible line. With the default always-on display this is the current
turn. If no baseline exists — most notably the first reply after upgrading in an existing thread —
the line is labelled `session input ...` and says that per-turn deltas begin with the next reply.

Codex's JSONL does not expose the latest request's prompt size or the current context-window fill,
so its section cannot honestly show Claude's `context`, request count, prefix-rewrite diagnosis, or
`warn_context` warning. The input/cached/output/reasoning totals remain exact. Backends that expose
neither usage shape leave the section absent rather than printing zeros.

For Claude, **`warn_context` is where a chat is worth splitting**, and the default comes from
measurement rather than taste. Over 30 days of session logs, the rate at which a request fails to
reuse the cached prefix — and then re-writes a byte-identical prefix at cache-creation price,
12.5× the read price — tracks context size directly:

| Context   | Requests | Rewrite rate | Cache created per request |
| --------- | -------- | ------------ | ------------------------- |
| under 30k | 1,158    | 0%           | 6,070                     |
| 30–80k    | 6,553    | 1.1%         | 6,146                     |
| 80–150k   | 7,218    | 4.8%         | 6,952                     |
| over 150k | 10,230   | 6.9%         | 20,334                    |

Past 150k both factors turn against you at once, which is what the threshold marks. At or above
it the section gains a warning under the metrics:

```markdown
### Tokens

context 205k · 12 requests · read 2.4M · new 12k

> ⚠️ **Context is 205k.** Every tool call re-reads all of it, and above 150k a request grows
> likelier to re-pay for a prefix it had already cached. Consider `/compact`,
> `:VibingChatHandoff` to continue in a new chat from a summary, or handing the
> exploring to a subagent.
```

It is written into the buffer, not raised with `vim.notify`, and it repeats on every turn that
stays above the threshold. A notification is gone by the time the next turn is read, which leaves
the one moment the cost is actually being looked at — the section right above it — saying nothing.
Repetition is what makes it a gauge rather than an announcement; keeping it to three lines is what
keeps it from being noise.

**A CLI's default auto-compaction does not remove the need for this.** Claude's does run under
`claude -p` — verified in this project's own logs — but it fires near the model's context ceiling,
measured at ~930k. It is a mechanism for not overflowing, not for controlling cost: every request
on the way up to 930k was already billed at the size it had reached. In one such session, the 452
requests made above 300k accounted for 84% of its cost while being 62% of its requests. Running the
same work at 80k would have cost 42% less on cache reads alone. The configured Codex path below
exists for the same reason: it brings Codex's native trigger forward to the chosen threshold.

**Manual `/compact` does**, and it is what the warning names. It reaches the CLI because an
unrecognised slash command falls through from the chat as prompt text; measured against claude
2.1.231 in headless `-p` mode, the turn emits a `compact_boundary`, produces no reply text, and
the session carries on afterwards under the same id.

It is not free, though, and the number is worth knowing before reaching for it: compaction
replaces the conversation with a summary, so the whole prefix changes and the next request is a
cold start. Measured on a small session, the turn after `/compact` wrote 79,783 tokens of new
cache. That pays for itself on a chat carrying hundreds of thousands of tokens of history and does
not on one that has barely grown — which is another way of saying the same thing the table above
says.

**`:VibingChatHandoff` is the other exit, and the cheaper one once the cache is cold.** It
summarizes the chat and opens a new one whose first message carries the summary, so the next
request costs the floor plus a few thousand tokens, and every request after that reads the same.
`/compact` wins while the cache is warm (it reads the conversation at cache-read price and rewrites
only floor + summary), but after the 1-hour TTL a `/compact` has to re-read the whole conversation
at creation price before it can summarize anything — on a 200k chat that is roughly 280k written
against roughly 115k for a handoff. The summary is put in the message rather than left for the
model to `Read`, because a tool call is one more request over the whole context and the file
would then stay in every later one. See `handbook/architecture/chat-lineage.md` → "Handoff Chat".

`/summarize` is **not** the tool for this, despite the name. It opens a summary in a floating
window and never touches the session, so the turn after it re-reads exactly as much as the turn
before.

**A re-write is not always the conversation's fault.** The prefix starts with the system prompt,
so anything the CLI computes _at process start_ and puts there is re-computed on every turn —
vibing.nvim restarts the CLI per turn, where an interactive session or Claude Code on the web keeps
one process for the whole conversation. If that value changes, the miss is total: floor plus the
entire history, at creation price. The known case is the CLI's git status block (branch,
`git status --short`, recent commits), which is why `agent.git_instructions` defaults to `false`
(#681).

Measured on a 128k-token session, comparing the turn right after a one-line edit to `README.md`:

| `git_instructions` | `new`   | `read`  |
| ------------------ | ------- | ------- |
| `true`             | 128,456 | 144,076 |
| `false`            | 9       | 272,424 |

The turn processes the same ~272k of input either way; what moves is the **price tier** it is
processed at. Priced in base-input-token equivalents (creation 1.25×, read 0.10×) that turn costs
174,978 against 27,254 — the block-on turn pays 6.4× as much for the same conversation. Note that
the CLI's fixed system prefix (the 144,076 read in both rows) stays cached: the block sits between
it and the conversation, so what misses is everything the chat has accumulated. That is what makes
the loss proportional to `context`.

The saving applies only to a turn that changed the tree, and one `git status` the model runs
because the block is gone costs one extra request over the whole context at read price — 27k
equivalents here, so it would take about five such calls per turn to give the saving back.

The same shape can come from anything else startup-computed; the invariant to apply when touching
this path is in `handbook/architecture/cli-integration.md` → "What the System Prompt May Not
Contain".

#### When a turn re-paid for its prefix

The table further up is about the odds of a rewrite. When one actually happens, the section says so
and names what caused it:

```markdown
### Tokens <!-- context=205431 -->

context 205k · 3 requests · read 410k · new 198k

> ↻ **Prefix rewritten (198k).** Likely cause: 1h12m since the last turn (the prompt cache TTL
> is 1h).
```

The fact was already in the numbers — `new` sitting close to `context` — but only for a reader who
knew to compare them. A turn counts as a rewrite when its **first** request writes at least half
its prompt. The first request is the one that either found the conversation's prefix or did not;
the turn's summed `new` cannot answer it, because every later request writes its own increment and
a turn with enough tool calls therefore out-writes its own context while hitting the cache every
time. The half is not configurable, unlike `warn_context`: it is a claim about what happened rather
than a taste about how noisy to be, and an ordinary turn appending to a warm prefix writes a few
percent.

Five causes are checked, in this order, and every one that applies is listed:

| Cause                                                                      | How it is established                            |
| -------------------------------------------------------------------------- | ------------------------------------------------ |
| The 1-hour cache TTL expired                                               | Previous turn's end to this turn's first request |
| The model or the effort changed                                            | Compared against the previous turn's values      |
| `CLAUDE.md`, `.claude/rules/*.md` or `.vibing/system-prompt.md` was edited | File mtimes, project and `~/.claude` alike       |
| The previous turn compacted the conversation                               | Its `compact_boundary` stream event              |
| Claude Code was updated                                                    | The `claude_code_version` in the `init` event    |

The third one is the one worth knowing about, because it behaves differently here than in the
terminal. `claude -p` starts a fresh process every turn, so an edit to `CLAUDE.md` or a rules file
takes effect on the **very next turn** — interactive mode holds the copy it started with until
`/clear` or `/compact`. In a repository where those files are edited often, that is a rewrite the
reader has no reason to suspect.

The second row is two checks rather than one, so a turn that changed both the model and the effort
lists them on separate lines. The rows are the kinds of cause, not a bound on how many lines a
single turn can produce.

A turn where none of the five applies says `No likely cause found` rather than picking one, and the
first turn of a session is never flagged: it writes its whole prefix by definition, because that is
the cache being filled rather than missed.

Comparing against the previous turn needs three facts that die with the CLI process — the model it
resolved, its version, and whether it compacted — so they are kept in `.vibing/turn-state.json`,
one record per chat, swept of anything older than 30 days. Deleting that file costs one turn of
`No likely cause found` and nothing else.

#### Warning before a send that rewrites an expired cache

`cache_ttl_sec` is the time half of the same story: it catches that cold-cache case _before_ the
send rather than after. On a 205k chat, resuming after lunch costs more in one send than starting
two new chats would, and vibing.nvim already has both facts on hand, so `<CR>` asks once:

```text
This chat's prompt cache has likely expired: the last turn ended 1h23m ago,
so sending now rewrites ~205k tokens.

1. Send anyway
2. Continue in a new chat (moves this message there)
3. Cancel
```

Both conditions have to hold. Either one alone would make the prompt routine noise: a large chat
answered promptly still has its cache, and a small chat left overnight rewrites almost nothing.
The default is 3300 seconds (55 minutes) rather than a full hour because the TTL is not reported
anywhere in the response and can only be inferred from the clock, so the check leans towards
catching a send that lands just inside it. Set `cache_ttl_sec = 0` to turn the prompt off; a
`warn_context = 0` turns it off too, since that already means "show the metrics, skip the
advice".

The elapsed time is measured from the **`## Assistant` header of the last completed turn**, which
is stamped when the turn ends for exactly this reason — the last API request of a turn is when the
cache was last written, and a long turn's start time can be twenty minutes earlier. The context
figure comes from the marker on that turn's own `### Tokens` heading
(`### Tokens <!-- context=205431 -->`), which carries the exact number the rounded metrics line
below it cannot: `149,600` displays as `150k`, and reading _that_ back would fire the prompt on a
chat sitting just under the threshold. Neither is borrowed from an older turn — a backend that
reports no usage simply produces no prompt — and the context figure is read only from inside that
turn's `### Tokens` section, since a reply is free to contain a sentence starting `context 8 …`.

Both survive a Neovim restart because the chat file is now saved **after** the turn's footer is
written. The existing auto-save runs when the session id is recorded, which is earlier in the same
turn, so on its own it left the file one turn behind — and the most recent turn, the one this
check is about, never on disk at all.

"Continue in a new chat" writes a new chat that inherits this one's model, effort, permissions and
`working_dir`, moves the unsent message into its first `## User` section, and leaves the source
chat where it was. It deliberately does **not** summarize first: generating a summary is itself a
request that reads the whole conversation at the price this prompt exists to avoid. When the
context is worth carrying, `:VibingChatHandoff` is the command that does it, and the warning above
already names it.

The prompt appears only for a `<CR>` a person typed. A scheduled request firing, an auto-resume,
a message delivered from another chat, and an orchestrator's delegated approval all reach the same
send path, and none of them can answer a picker — so the gate lives in the chat buffer's keymap
rather than in `send_message()`. Slash commands and replies to a pending tool-approval prompt are
excluded for the same reason `scheduled_requests` excludes them: neither has any reason to be
delayed. Anything that fails inside the check sends the message rather than blocking it.

One more thing the numbers depend on: **a chat has a floor it can never go below**, made of the
system prompt, the tool schemas, and whatever `CLAUDE.md` and `.claude/rules/` the project loads.
The first turn of a session reports it, since that is the one turn whose context _is_ the floor:

```markdown
context 112k · 2 requests · read 112k · new 112k
floor ~112k (322 tools, 23 MCP servers)
```

The two counts come from the CLI's `init` event, which is the only thing that states them. In this
repository the floor is about 110k — so `warn_context = 150000` leaves only ~40k of conversation
before the warning appears. In a project with a small `CLAUDE.md` the same threshold is a long way
up. If the warning fires constantly, that is what to raise it against.

`warn_context = 0` is the middle setting: the metrics stay, the warning never appears. Use it if
the numbers are what you wanted and the nudge is not. `enabled = false` removes the section
entirely.

### Automatic compaction

`agent.token_usage.auto_compact` uses one setting for the two backends that expose compaction:

```lua
token_usage = {
  auto_compact = {
    enabled = true,
    at = 200000,
    focus = "the open tasks and the files changed so far",
  },
}
```

On **Claude**, the compaction is inserted before your next manual send, not right after the turn
that crossed the threshold. The turn following a compaction re-writes the whole prefix, so
crossing 200k and then moving to a fresh chat would have paid ~80k for nothing. Waiting until you
actually type again is what ties the spend to the intent to keep going. What you see is two turns:
`/compact`, then your message, whose `### Tokens` reports the smaller context.

On **Codex**, every ordinary `codex exec` invocation, both new and resumed, gets
`-c model_auto_compact_token_limit=<at>`. Codex tracks its own context and compacts inside the
normal turn when that threshold is reached. There is no preliminary prompt turn, and the trigger
still works even though Codex's JSONL stream does not expose the current context figure needed for
`warn_context`. Lightweight utility calls such as title generation and `/summarize` do not inherit
the chat threshold.

`enabled = false` means vibing.nvim supplies no override. It does not disable either CLI's own
default near-limit compaction. `at <= 0` likewise disables vibing.nvim's trigger/override.

For Claude, `at` sits above `warn_context` deliberately. The warning is where you get to choose
between `/compact`, `:VibingChatHandoff` and handing the exploring to a subagent; a threshold that
fired at the same place would take that choice away at the moment it is being offered. Codex does
not currently produce that warning because its stream does not report current context fill.

`focus` is Claude-only and is worth setting there. What the summary keeps decides how well every
later turn goes, and the CLI's own default summary is general. There is no default here because a
wrong one would shape every summary without ever announcing itself. Codex uses `enabled` and `at`;
vibing.nvim does not translate `focus` into a Codex compaction prompt.

Claude compares against the same figure the cache prompt above uses: the marker on the **last
completed turn's** `### Tokens` heading, read through the same helper. It is deliberately not a
fresh scan for the last heading anywhere in the buffer — the rounded fallback matches any line
beginning `context <number>`, which a reply is free to write. Codex performs this comparison
internally against its live context instead.

The Claude insertion has three additional limits, each of which refuses to spend tokens you did not
ask it to:

- **Manual sends only.** A scheduled request, an auto-resume, and a message delivered from
  another chat all send without you present; none of them triggers a compaction. This matches how
  the rest of the unattended paths are bounded.
- **At most every other manual send.** If a compaction fails to shrink the conversation, the next
  send goes out on its own rather than compacting again — otherwise every send from then on would
  cost two turns.
- **Not while a usage limit is on record for this chat's backend.** A limit would reject the
  compaction turn, and a rejected turn writes its own message back into the unsent section —
  over the message being parked there.

A send whose message is a slash command or an answer to a pending approval prompt is left alone.
That judgement is not re-derived here: all three interceptions on the `<CR>` path — the
limit-aware reschedule, the expired-cache prompt, and this — ask `can_defer_send`.

On Claude, the expired-cache prompt comes first on the `<CR>` path and compaction second. If you
call the send off at that prompt, nothing has been rewritten yet. It also means a cold cache is
reported at its real size — the figure that makes "continue in a new chat" the cheaper answer —
before a compaction can shrink it.

`:VibingCompact [focus]` is the manual version: one `/compact` turn, now, with an optional focus.
It refuses while an unsent message is waiting — the automatic path parks your message because you
asked to send _that message_, whereas this command was typed on its own and should mean exactly
one turn. The command remains Claude-only; Codex exposes automatic compaction here, not a matching
manual slash command.

### Claude CLI Environment Variables

Several of Claude Code's cost knobs have no flag and no settings key — the environment is the only
way in ([env vars](https://code.claude.com/docs/en/env-vars.md),
[costs](https://code.claude.com/docs/en/costs.md#reduce-token-usage)). `vim.env.X = ...` in your
`init.lua` reaches the CLI child, because the spawn inherits `vim.fn.environ()`, but it also
reaches every `claude` you start from a terminal in that Neovim, and it cannot differ per chat.
`agent.env` is the scoped version:

```lua
agent = {
  env = {
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = "20",
    BASH_MAX_OUTPUT_LENGTH = "10000",
  },
},
```

| Variable                          | Effect                                                                                          |
| --------------------------------- | ----------------------------------------------------------------------------------------------- |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | Percentage of the context window at which the CLI auto-compacts. See below                      |
| `BASH_MAX_OUTPUT_LENGTH`          | Cap on a `Bash` result, in characters (default 30,000)                                          |
| `CLAUDE_CODE_SUBAGENT_MODEL`      | Model a `Task`/`Agent` call runs on, e.g. `haiku` for exploration                               |
| `CLAUDE_CODE_PROMPT_CACHE_TTL`    | Prompt cache TTL                                                                                |
| `MAX_THINKING_TOKENS`             | Thinking budget on older models. Ignored by adaptive-thinking ones — use `agent.default_effort` |

**`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` is a percentage, so what it means depends on the model.** On a
1M-context model (`[1m]`) the default fires at roughly 930k tokens (#669), which is far past the
point where a turn is expensive; `20` brings that to ~200k. On a 200k model the same `20` fires at
40k, which is almost certainly too eager. Pick the number from the window your `default_model`
actually has, and re-check it when you change models. vibing.nvim's own
[`agent.token_usage.auto_compact`](#automatic-compaction) is the backend-independent alternative:
it is an absolute token count rather than a percentage, and it compacts between turns instead of
mid-turn.

**`BASH_MAX_OUTPUT_LENGTH` is usually the larger win.** A tool result is re-sent with every later
request in the conversation, so one 30k-character test run is paid for on every turn after it, not
once.

Three rules apply to whatever you put here:

- **A chat's `env:` frontmatter wins**, so one chat can lower `BASH_MAX_OUTPUT_LENGTH` without
  touching the rest. It is a list of `KEY=VALUE` lines — `doc/vibing.txt` → "CHAT FILE FORMAT".
- **`CLAUDECODE` and `VIBING_*` are refused with a warning.** They carry the RPC port, the handle
  ID and the nested-invocation escape that the permission hook, the approval UI and the per-request
  diff baseline all ride on.
- **Lightweight utility calls get none of it** (title generation, `/summarize`, the daily summary).
  They run with no tools and no resumed session, so none of these variables has anything to act on.

A variable already present in Neovim's own environment is overwritten by `agent.env` — declaring it
here is the more specific statement. `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS` is worth naming
because it also has an option of its own: `agent.env` is merged first and `agent.git_instructions`
only fills a gap, so writing the variable here wins over that option.

Claude backend only. Codex, Copilot and Grok inherit Neovim's environment as before and read none
of these names.

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
fixed continuation prompt, it usually resends the chat's own message, unedited, at the chosen time
(the exception is a turn the limit interrupted mid-flight; see below). This is not limited to
usage-limit recovery: `:VibingSchedule 18:30` works with no limit ever having been hit. Two of the
three ways a scheduled request gets created, described below, are specifically about usage limits.

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

**A rejected turn that got somewhere parks a continuation, not its own message.** The first two
routes park a message that never ran, so the message is what should be sent. The third does not:
a limit can land part-way through a turn, after the model has already answered, edited files, or
run tools. Both that work and the request that asked for it are in the resumed session's
transcript, so re-sending the same text hands the model the same request a second time and invites
it to redo what it already did. When the rejected turn produced any output, vibing.nvim therefore
parks `auto_resume_on_limit.prompt` (default `"Continue from where you left off."`) instead — the
same sentence auto-resume uses, since it means the same thing. A turn the limit rejected at the
door, with nothing streamed and no file touched, still parks its own message unchanged. The
sentence lands in the unsent `## User` section like any other scheduled body, so it is visible and
editable while parked; the original request stays in the transcript above it. Note that
`auto_resume_on_limit.prompt` is read for its value alone — this works whether or not
`auto_resume_on_limit.enabled` is set.

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

The record also names the backend that hit the limit, and only chats on that backend are parked
by it. A usage limit belongs to one provider's plan, so a claude limit leaves a codex chat in the
same project free to send — and a codex response getting through does not clear the claude record.
Which backend a chat is on is its frontmatter `agent`, falling back to `adapter` in `setup()`.
`:VibingCancelResume` clears it only when it is the current chat's backend; `:VibingCancelResume
all` has no chat in hand and clears whatever is recorded.

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
project's recorded usage limit for this chat's backend — so "send now" (cancel, then `<CR>`)
actually sends instead of being re-parked by the stale record, without unparking chats on a
different backend. If the limit is genuinely still in force, the next rejected response re-records
it.

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

Each turn that runs a tool capable of touching a file takes a snapshot of the working tree as a
git tree object, and compares it against a second snapshot once the response completes. A turn
that only reads takes no snapshot, and the two fallback cases below use a lighter mechanism. The
resulting patch is stored under `.vibing/patches/` and listed in the chat as
`### Modified Files`; `gd` on one of those paths shows it.

Because the comparison is between two states of the whole tree, it does not matter which tool
made the change — **a `sed -i`, a `mv`, or a formatter run through Bash shows up the same way an
`Edit` does**. Untracked files matched by `.gitignore` are excluded (that is what keeps the cost
down) — a file that is already tracked still shows its changes even if it matches an ignore
pattern, because `.gitignore` only governs what gets added. An ignored file that a write tool
reported anyway is still listed under `### Modified Files`, just without a patch section.
vibing.nvim's own `.vibing/` directory is the exception: it is excluded from both the snapshot and
the tool-event completion, whether or not you have git-ignored it — the chat files live there and
would otherwise report themselves as your changes.

Your index and working tree are never touched: the snapshot is built with `git add -A` against a
temporary index (`GIT_INDEX_FILE`), so it takes no `.git/index.lock` and cannot collide with git
commands you run yourself. Nothing is committed to any branch — the snapshot commits are held by
a short-lived `refs/worktree/vibing/<request>` ref that is deleted as soon as the turn's patch is
written.

Two cases fall back to a lighter mechanism that only backs up the files a write tool named
(so Bash-driven changes are missed there): a `working_dir` that is not inside a git repository,
and a turn whose write window overlapped another chat's in the same worktree — the tree is shared,
so a snapshot could not tell whose change was whose. **Both** overlapping turns fall back, not just
one, so a Bash-driven change made while two chats were working in the same worktree is missed by
both of their diffs. It is still on disk; `git status` shows it.

That overlap check only sees chats **inside one Neovim**. Two Neovim instances open on the same
worktree cannot see each other's turns, so each takes the snapshot path and may report the other's
changes as its own — all of them, not only the Bash-driven ones, because a tree comparison carries
every change made in that window whatever produced it. Note the asymmetry with the ref cleanup,
which does check for other live instances: deleting a ref another process is relying on is an
action, while this is a misreading, and a turn has no cross-process identity to compare in the
first place. This is accepted rather than solved; run concurrent chats in separate worktrees,
which is what `working_dir` and the `vibing-worktree-*` skills are for.

There is a third route, for failure rather than routing: if the snapshot itself cannot be read —
a worktree removed mid-turn, a permission or disk error — the turn falls back to the same lighter
mechanism, so a Bash-driven change may be missing from that turn's diff even in a git worktree.
When the fallback has nothing either, vibing.nvim says so rather than showing an empty result.

```lua
diff = {
  tool = "auto",  -- "auto" / "git" — currently the same thing. Kept as a hook for
                  -- future backends; `gd` falls back to a plain `git diff` when a
                  -- turn has no patch file (e.g. an old chat reopened).
}
```

> **The opt-in `mote` backend has been removed**, along with `diff.mote`, `diff.tool = "mote"`,
> the `mote_dirs` / `mote_cwd` frontmatter keys, `:VibingMoteDir` and `:VibingCleanMote`. The
> snapshot path above covers what mote was there for (Bash-driven changes) without an external
> binary or any setup step. Nothing stops working if you leave the old settings in place — each
> warns once and is ignored, and `diff.tool = "mote"` behaves as `"git"` — so you can delete them
> whenever you get to it.

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

  codex_profile_file = ".vibing/codex-permissions.toml",
                         -- Codex only: project-local OS sandbox profile.
                         -- Set false to disable it.
  codex_allow_tracked_profile = false,
                         -- Set true only after reviewing a Git-tracked profile.
}
```

Valid tool names: `Read`, `Edit`, `Write`, `Bash`, `Glob`, `Grep`, `WebSearch`, `WebFetch`,
`Skill`, `StructuredOutput`. Bash command patterns (`Bash(git:*)`) and MCP tool names
(`mcp__server__tool`) are also accepted in the lists.

Two built-in behaviors to be aware of:

- `Read`, `Skill`, and `StructuredOutput` are **always allowed** regardless of the allow list
  (they can still be blocked via `deny`).
- `Skill` is automatically appended to `allow` unless you put it in `deny` or `ask`.

### Project-local Codex permission profiles

Codex normally discovers project configuration only at `.codex/config.toml`; it cannot be pointed
at an arbitrary config file. vibing.nvim bridges that gap for permissions: when
`permissions.codex_profile_file` exists, it reads the file and passes its effective values as
per-run `-c` overrides to both a new `codex exec` session and every `resume`. The default path is
`.vibing/codex-permissions.toml`, relative to the request working directory. vibing.nvim creates
that file when it initializes the project's `.vibing/` directory, and also backfills it when the
directory already exists but the file does not. Existing files, including empty ones, are never
overwritten. A worktree without its own copy falls back to the project root where Neovim started
only when both paths belong to the same Git repository. That shares one ignored policy across the
project's worktrees without leaking it into an unrelated project.

The file uses Codex's normal permission-profile table form. Values must be single-line TOML
scalars; this covers the current permission schema while keeping the loader permission-only. The
generated default allows normal workspace edits and Git metadata writes:

```toml
default_permissions = "vibing-project"

[permissions.vibing-project]
description = "Workspace editing with Git metadata access"
extends = ":workspace"

[permissions.vibing-project.filesystem.":workspace_roots"]
".git" = "write"
```

Network access remains disabled by default. Add this when the project needs it:

```toml
[permissions.vibing-project.network]
enabled = true
```

The loader accepts only `default_permissions`, `[permissions.*]`, and
`features.network_proxy`. It rejects `:danger-full-access`; select `bypassPermissions` explicitly
when full access is genuinely intended. Deleting the generated file causes it to be recreated on
the next project initialization; leave it empty to preserve the previous Codex behavior
(`workspace-write` for a new ordinary session), or set `codex_profile_file = false` to disable
loading it. `plan` and lightweight utility calls stay read-only, while explicit
`bypassPermissions` still wins over the project profile.

In a linked Git worktree, `.git` is a file that points outside the checkout. When the selected
profile grants `.git = "write"`, vibing.nvim resolves Git's common metadata directory and adds the
same write rule there. This lets `git add`, `commit`, branch and worktree operations behave the same
in a main checkout and a linked worktree without granting write access to the main working tree.

Permission files are read locally and converted into deterministically sorted command arguments;
their path and source text are not inserted into the model prompt. Keeping the effective profile
unchanged therefore keeps the permission portion of the prompt-cache prefix unchanged. Editing
the effective profile can change that prefix, as it should. The file is read before each ordinary
turn, so edits take effect without restarting Neovim.

Two boundaries remain separate:

- Do not keep `sandbox_mode` or `sandbox_workspace_write` in any loaded Codex config, because
  Codex gives those legacy settings precedence over permission profiles.
- The profile controls Codex's OS sandbox. vibing.nvim's tool permissions still apply, so `Bash`
  must also be allowed in the chat before Codex can run Git commands.

This file can grant local filesystem and network access. `.vibing/` is normally git-ignored, and
locally generated, untracked profiles load automatically. A repository can nevertheless force-add
an ignored file, so Git-tracked profiles fail closed by default. After reviewing one, set
`permissions.codex_allow_tracked_profile = true` to trust it explicitly.

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

Node is only needed to build the MCP server at install time; nothing vibing.nvim does at runtime
spawns it. `VIBING_NODE_EXECUTABLE` picks the binary `build.sh` uses:

```bash
VIBING_NODE_EXECUTABLE=/usr/local/bin/bun ./build.sh
```

Or in your lazy.nvim spec:

```lua
{
  "shabaraba/vibing.nvim",
  build = "VIBING_NODE_EXECUTABLE=/usr/local/bin/bun ./build.sh",
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
